package WebworkBridge::Parser;

##### Library Imports #####
use strict;
use warnings;

use WeBWorK::Debug;

use WebworkBridge::Importer::Error;

# Constructor
sub new
{
	my ($class, $r, $course_ref, $students_ref) = @_;

	my $self = {
		r => $r,
		course => $course_ref,
		students => $students_ref
	};

	bless $self, $class;
	return $self;
}

sub parse
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub parseStudent
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub parseCourse
{
	my ($self, $param) = @_;
	die "Not implemented";
}

sub getCourseName
{
	my ($self, $course, $section) = @_;
	my $r = $self->{r};
	my $ce = $r->ce;

	# read configuration to see if there are any custom mappings we
	# should use instead
	my $origname;
	if ($section)
	{	
		$origname = $course . ' - ' . $section;
	}
	else
	{
		$origname = $course;
	}

	# course name mapping has three levels, start from highest priority
	# 1. custom course mapping 
 	# 2. course mapping rules
	# 3. using the name as is
	for my $key (keys %{$ce->{bridge}{custom_course_mapping}})
	{
		if ($origname eq $key)
		{
			my $val = sanitizeCourseName($ce->{bridge}{custom_course_mapping}{$key});
			debug("Using custom mapping for course '$origname' to '$val'");
			return $val;
		}
	}

	for my $key (keys %{$ce->{bridge}{course_mapping_rules}})
	{
		my $val = $ce->{bridge}{course_mapping_rules}{$key};
		my $regex = qr/$key/;
		if ($origname =~ $regex)
		{
			my $cname = eval($val);
			my $ret = sanitizeCourseName($cname);
			debug("Using mapping rules for course '$origname' to '$ret'");
			return $ret;
		}
	}

	# if no configuration, then we build our own course name 
	$section ||= '';
	my $sectionnum = $section;
	$sectionnum =~ m/(\d\d\d[A-Za-z]|\d\d\d)/g;
	$sectionnum = $1;

	my $ret;
	if ($sectionnum)
	{
		$ret = $course .'-'. $sectionnum;
	}
	elsif ($section)
	{
		$ret = $course . '-' . $section;	
	}
	else
	{
		$ret = $course;
	}
	$ret = sanitizeCourseName($ret);

	return $ret;
}

sub sanitizeCourseName
{
	my $course = shift;
	# replace spaces with underscores cause the addcourse script can't handle
	# spaces in course names and we want to keep the course name readable
	$course =~ s/ /_/g;
	$course =~ s/[^a-zA-Z0-9_-]//g;
	$course = substr($course,0,40); # needs to fit mysql table name limits
	# max length of a mysql table name is 64 chars, however, webworks stick
	# additional characters after the course name, so, to be safe, we'll
	# have an error margin of 24 chars.
	return $course;
}

1;
