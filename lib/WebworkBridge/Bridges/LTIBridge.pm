package WebworkBridge::Bridges::LTIBridge;
use base qw(WebworkBridge::Bridge);

##### Library Imports #####
use strict;
use warnings;

use UNIVERSAL 'isa';
use Net::OAuth;
use HTTP::Request::Common;
use LWP::UserAgent;
use Data::Dumper;

use WeBWorK::CourseEnvironment;
use WeBWorK::DB;
use WeBWorK::Debug;
use WeBWorK::Utils qw(runtime_use readFile cryptPassword);

use WebworkBridge::Exporter::GradesExport;
use WebworkBridge::Importer::Error;
use WebworkBridge::Parser;
use WebworkBridge::Bridges::LTIParser;
use WeBWorK::Authen::LTI;

# Constructor
sub new 
{
	my ($class, $r) = @_;
	my $self = $class->SUPER::new($r);
	bless $self, $class;
	return $self;
}

sub accept
{
	my $self = shift;
	my $r = $self->{r};
	
	if ($r->param("lti_message_type"))
	{
		return 1;
	}

	return 0;
}

# In order to simplify, we use the Webwork root URL for all LTI actions,
# e.g.: http://137.82.12.77/webworkdev/
# Cases to handle:
# * The course does not yet exist
# ** If user is instructor, ask if want to create course
# ** If user is student, inform that course does not exist
# * The course exists
# ** SSO login

sub run
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	if ($r->param("lti_message_type") &&
		$r->param("context_label"))
	{
		debug("LTI detected\n");
		# Check for course existence

		my $parser = WebworkBridge::Bridges::LTIParser->new($r);
		my $coursename = $parser->getCourseName($r->param("context_label"));
		my $tmpce = WeBWorK::CourseEnvironment->new({
				%WeBWorK::SeedCE,
				courseName => $coursename
			});
		if (-e $tmpce->{courseDirs}->{root})
		{ # course exists
			debug("We're trying to authenticate to an existing course.");
			if ($ce->{"courseName"})
			{
				debug("CourseID found, trying authentication\n");
				$self->{useAuthenModule} = 1;
				if (my $tmp = $self->_verifyMessage())
				{
					return $tmp;
				}
                
				return $self->updateCourse();
			}
			else
			{
				debug("CourseID not found, trying workaround\n");
				# workaround is basically dump all our POST parameters into
				# GET and redirect to that url. This should work as long as
				# our url doesn't exceed 2000 characters.
				use URI::Escape;
				my @tmp;
				foreach my $key ($r->param) {
					my $val = $r->param($key);
					push(@tmp, "$key=" . uri_escape($val)); 	
				}
				my $args = join('&', @tmp);

				use CGI;
				my $q = CGI->new();
				my $redir = $r->uri . $coursename . "/?". $args;
				print $q->redirect($redir);
			}
		}
		else
		{ # course does not exist
			debug("Course does not exist, try LTI import.");
			$self->{useDisplayModule} = 1;
			if (my $tmp = $self->_verifyMessage())
			{
				return $tmp;
			}

			return $self->createCourse();
		}
	}
	else
	{
		debug("LTI detected but unable to proceed, missing parameter 'context_label'.\n");
	}

}

sub getAuthenModule
{
	my $self = shift;
	my $r = $self->{r};
	return WeBWorK::Authen::class($r->ce, "lti");
}

# Uncomment if needed to override the default display module
#sub getDisplayModule
#{
#	my $self = shift;
#	return "WeBWorK::ContentGenerator::LTIImport";
#}

sub createCourse
{
	my $self = shift;
	my $r = $self->{r};

	my %course = ();
	my @students = ();

	if (!$self->_isInstructor())
	{
		return error("Please ask your instructor to import this course into Webworks first.", "#e011");
	}

	my $ret = $self->_getAndParseRoster(\%course, \@students);
	if ($ret)
	{
		return error("Get roster failed: $ret", "#e009");
	}

	$ret = $self->SUPER::createCourse(\%course, \@students);
	if ($ret)
	{
		return error("Create course failed: $ret", "#e010");
	}

	# store LTI credentials for auto-update
	my $file = $r->ce->{bridge}{lti_loginlist};
	my @fields = (
		$r->param('lis_person_sourcedid'),
		$course{name},
		$r->param('ext_ims_lis_memberships_id'),
		$r->param('ext_ims_lis_memberships_url'),
		$r->param('oauth_consumer_key'),
		$r->param('context_label')
	);
	$self->updateLoginList($file, \@fields);

	return 0;
}

sub updateCourse
{
	my $self = shift;
	my $r = $self->{r};
	my $ce = $r->ce;

	debug("Checking to see if we can update the course.");
	# check roles to see if we can run update
	if (!defined($r->param('roles')))
	{
		return error("LTI launch missing roles, NOT updating course.", "#e025");
	}
	my @roles = split(/,/, $r->param("roles"));
	my $allowedUpdate = 0;
	foreach my $role (@roles) 
	{
		if ($ce->{bridge}{roles_can_update} =~ /$role/) 
		{
			debug("Role $role allowed to update course.");
			$allowedUpdate = 1;
			last;
		}
	}
	if (!$allowedUpdate)
	{
		return error("User not allowed to update course.");
	}

	my %course = ();
	my @students = ();

	# try to update course enrolment
	my $ret = $self->_updateCourseEnrolment(\%course, \@students);
	if ($ret)
	{ # failed to update course enrolment, stop here
		debug("Course enrolment update failed, bailing.");
		return $ret;
	}

	# try to push out grades back to the LMS
	$ret = $self->_pushGrades(\@students);

	return $ret;
}

# Push grades from Webwork to the lms
sub _pushGrades()
{
	my ($self, $studentsList) = @_;
	my $r = $self->{r};
	unless ($r->param("ext_ims_lis_basic_outcome_url"))
	{
		debug("Server does not allow outcome submissions.\n");
		return 0;
	}

	my %students = map {($_->{'loginid'} => $_)} @$studentsList;

	my $grades = WebworkBridge::Exporter::GradesExport->new($r);
	my $scores = $grades->getGrades();
	while (my ($studentID, $records) = each(%$scores))
	{
		while (my ($setName, $setRecords) = each(%$records))
		{
			$self->_pushGrade($setName, $setRecords, $studentID, \%students);
		}
	}

	return 0;
}

# Sync course enrolment from the lms with Webwork
sub _updateCourseEnrolment()
{
	my ($self, $course, $students) = @_;

	debug("Trying to update course enrolment.");
	my $r = $self->{r};
	unless ($r->param("ext_ims_lis_memberships_url"))
	{
		debug("Server does not allow roster retrival.\n");
		return 0;
	}

	my $ret = $self->_getAndParseRoster($course, $students);
	if ($ret)
	{
		return error("Get roster failed: $ret", "#e009");
	}

	if (@$students) 
	{
		$ret = $self->SUPER::updateCourse($course, $students);
		if ($ret)
		{
			return error("Update course failed: $ret", "#e010");
		}
	}
	return 0;
}

sub _pushGrade()
{
	my ($self, $name,  $record, $userid, $students) = @_;
	if (ref($record) eq 'ARRAY')
	{
	}
	else
	{
		if ($record->{status})
		{
			my $score = $record->{totalRight}. "/" .$record->{total};
			$self->_ltiUpdateGrade($name, $score, $students->{$userid});
		}
	}
}

sub _ltiUpdateGrade()
{
	my ($self, $name, $score, $student) = @_;
	my $r = $self->{r};
	my $ce = $r->ce;

	my $user = $student->{'sourcedid'} . ":$name";
	my $courseURL = $r->param("ext_ims_lis_basic_outcome_url");
	my $key = $r->param("oauth_consumer_key");
	my $secret = $ce->{bridge}{$key};

	my $request = Net::OAuth->request("request token")->new(
		consumer_key => $key,
		consumer_secret => $secret,
		protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
		request_url => $courseURL,
		request_method => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp => time(),
		nonce => rand(),
		callback => 'about:blank',
		extra_params => {
			lti_version => 'LTI-1p0',
			lti_message_type => 'basic-lis-updateresult',
			sourcedid => $user,
			result_resultscore_textstring => $score,
			result_resultvaluesourcedid => 'ratio',
			# Optional parameters, may not be supported
			#result_resultscore_language => 'en_US',
			#result_statusofresult => 'final',
			#result_date => strftime("%Y-%m-%dT%H:%M:%S", gmtime(time())) . 'Z',
			#result_datasource => 'blah'
		}
	);
	$request->sign;

	my $ua = LWP::UserAgent->new;
	push @{ $ua->requests_redirectable }, 'POST';

	my $res = $ua->post($courseURL, $request->to_hash);
	if ($res->is_success) 
	{
		debug($res->content . "\n");
		if ($res->content =~ /codemajor>Failure/)
		{
			debug("Grade update failed, unable to authenticate.");
		}
	}
	else
	{
		debug("Grade update failed, POST request failed.");
	}
}

sub _isInstructor
{
	my $self = shift;
	my $r = $self->{r};

	if ($r->param('roles') =~ /instructor/i ||
		$r->param('roles') =~ /contentdeveloper/i)
	{
		return 1;
	}
	return 0;
}

sub _getAndParseRoster
{
	my ($self, $course_ref, $students_ref) = @_;
	my $r = $self->{r};
	
	my $xml;
	my $ret = $self->_getRoster(\$xml);
	if ($ret)
	{
		return error("Unable to connect to roster server: $ret", "#e003");
	}

	my $parser = WebworkBridge::Bridges::LTIParser->new($r, $course_ref, $students_ref);
	$ret = $parser->parse($xml);
	if ($ret)
	{
		return error("XML response received, but access denied.", "#e005");
	}
	$course_ref->{name} = $parser->getCourseName($r->param("context_label"));
	$course_ref->{title} = $r->param("resource_link_title");
	$course_ref->{id} = $r->param("resource_link_id");

	return 0;
}

sub _getRoster
{
	my ($self, $xml) = @_;
	my $r = $self->{r};

	my $ua = LWP::UserAgent->new;
	my $key = $r->param('oauth_consumer_key');
	if (!defined($r->ce->{bridge}{$key}))
	{
		return error("Unknown secret key '$key', is there a typo?", "#e006");
	}
	my $request = Net::OAuth->request("request token")->new(
		consumer_key => $key,
		consumer_secret => $r->ce->{bridge}{$key},
		protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0A,
		request_url => $r->param('ext_ims_lis_memberships_url'),
		request_method => 'POST',
		signature_method => 'HMAC-SHA1',
		timestamp => time(),
		nonce => rand(),
		callback => 'about:blank',
		extra_params => {
			lti_version => 'LTI-1p0',
			lti_message_type => 'basic-lis-readmembershipsforcontext',
			id => $r->param('ext_ims_lis_memberships_id'),
		}
	);
	$request->sign;

	# remove the params in URL from post body so that they will not be send twice
	my @params = split('&', uri_unescape($request->to_post_body));
	my $url = URI->new($request->request_url);
	foreach my $k ($url->query_param) {
		@params = grep {$_ ne $k.'='.$url->query_param($k)} @params;
	}	

	# have to generate the post parameters oursevles because of the way blti building block check the hash (membeships_id)
	my %p = map { (split('=', $_, 2))[0] => (split('=', $_, 2))[1] } @params;
	my $res = $ua->request((POST $request->request_url, \%p));
	if ($res->is_success) 
	{
		$$xml = $res->content;
		debug("LTI Get Roster Success! \n" . $$xml . "\n");	
		return 0;
	}
	else
	{
		return error("Unable to perform OAuth request.","#e007");
	}
}

sub _verifyMessage()
{
	my $self = shift;
	my $r = $self->{r};
	# verify that the message hasn't been tampered with 
	my $ltiauthen = WeBWorK::Authen::LTI->new($r);
	my $ret = $ltiauthen->authenticate();
	if (!$ret)
	{
		return error("Error: LTI message integrity could not be verified. Check if the LTI launch URL has a trailing slash.","#e015");
	}
	return 0;
}

1;
