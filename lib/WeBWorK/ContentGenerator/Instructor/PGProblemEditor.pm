package WeBWorK::ContentGenerator::Instructor::PGProblemEditor;
use base qw(WeBWorK::ContentGenerator::Instructor);


=head1 NAME

WeBWorK::ContentGenerator::Instructor::ProblemSetEditor - Edit a set definition list

=cut

use strict;
use warnings;
use CGI qw();
use WeBWorK::Utils qw(readFile);
use Apache::Constants qw(:common REDIRECT);


our $libraryName;
our $rowheight;

sub title {
	my $self = shift;
	#FIXME  don't need the entire path  ??
	return "Instructor Tools - PG Problem Editor for ". $self->{problemPath};
}
sub go {
	my $self 			= shift;
	my ($setName, $problemNumber) = @_;
	my $r 				= 	$self->{r};
	my $ce				=	$self->{ce};
	my $submit_button 	= $r->param('submit');  # obtain submit command from form

	# various actions depending on state.
	if (     defined($submit_button) and ($submit_button eq 'Save' or $submit_button eq 'Refresh')    ) {
	
		$self->initialize($setName,$problemNumber);  # write the necessary files
													 # return file path for viewing problem
													 # in $self->{currentSourceFilePath}
		#redirect to view the problem
		
		my $hostname 		= 	$r->hostname();
		my $port     		= 	$r->get_server_port();
		my $uri		 		= 	$r->uri;
		my $courseName		=	$self->{ce}->{courseName};
		my $editFileSuffix  =	$self->{ce}->{editFileSuffix};
		my $problemSeed		= 	($r->param('problemSeed')) ? $r->param('problemSeed') : '';
		my $displayMode		=	($r->param('displayMode')) ? $r->param('displayMode') : '';

		my $viewURL  		= 	"http://$hostname:$port";
		$viewURL		   .= 	$ce->{webworkURLs}->{root}."/$courseName/$setName/$problemNumber/?";
		$viewURL		   .=	$self->url_authen_args;
		$viewURL		   .=   "&displayMode=$displayMode&problemSeed=$problemSeed";   # optional displayMode and problemSeed overrides
		if ($submit_button eq 'Save') {
			$viewURL		   .=	"&editMode=savedFile";
		} else {		
			$viewURL		   .=	"&editMode=temporaryFile";
		}
		$viewURL		   .=	'&sourceFilePath='. $self->{currentSourceFilePath}; # path to pg text for viewing
		#$viewURL		   .=	"&submit_button=$submit_button";                   # allows Problem.pg to recognize state
#		$viewURL		   .=   '&editErrors='.$self->{editErrors};																				 # of problem being viewed.
		$r->header_out(Location => $viewURL );
		return REDIRECT;
	} else {
		# initialize and 
		# display the editing window
		
		$self->SUPER::go(@_);
	}

}

sub initialize {
	
	my ($self, $setName, $problemNumber) = @_;
	my $ce 						= 	$self->{ce};
	my $r						=	$self->{r};
	my $path_info 				= 	$r->path_info || "";
	my $db						=	$self->{db};
	my $user					=	$r->param('user');
	my $effectiveUserName		=	$r->param('effectiveUser');
	my $courseName				=	$ce->{courseName};

#   FIXME -- sometimes this doesn't find a set	
#	my $set            			= 	$db->getMergedSet($effectiveUserName, $setName);
#	my $setID					=	$set->set_id;
	
	# Find URL for viewing problem
	
	# find path to pg file for the problem
	# FIXME  there is a discrepancy in the way that the problems are found.
	# FIXME  more error checking is needed in case the problem doesn't exist.
	# my $problem_record		=	$db->getUserProblem($user,$setID,1);
	my $problem_record			=	$db->getMergedProblem($effectiveUserName, $setName, $problemNumber);
	# If there is no global_user defined problem, (i.e. the sets haven't been assigned yet), then look for a global version of the problem.
	$problem_record			    =	$db->getGlobalProblem($setName, $problemNumber) unless defined($problem_record);
	die "Cannot find a problem record for set $setName / problem $problemNumber" 
		unless defined($problem_record);
	my $templateDirectory		=	$ce->{courseDirs}->{templates};
	my $problemPath				=	$templateDirectory."/".$problem_record->source_file;
	my $editFileSuffix			=	'tmp';
	my $submit_button			= 	$r->param('submit');

	my $displayMode	  			= 	( defined($r->param('displayMode')) 	) ? $r->param('displayMode') : $ce->{pg}->{options}->{displayMode};
	# try to get problem seed from the input parameter, or from the problem record
	my $problemSeed;
	if ( defined($r->param('problemSeed'))	) {
		$problemSeed            =   $r->param('problemSeed');	
	} elsif ($problem_record->can('problem_seed')) {
		$problemSeed            =   $problem_record->problem_seed;
	}
	# make absolutely sure that the problem seed is defined, if it hasn't been.
	$problemSeed				=	'123456' unless defined($problemSeed) and $problemSeed =~/\S/;
	
	my $problemContents	= '';
	my $currentSourceFilePath	=	'';
	my $editErrors = '';
	# update the .pg and .pg.tmp files in the directory
	if (not defined($submit_button) ) {
		# this is a fresh editing job
		# copy the pg file to a new file with the same name with .tmp added
		# store this name in the $self->currentSourceFilePath for use in body 
		
		eval { $problemContents			=	WeBWorK::Utils::readFile($problemPath)  
		};  # try to read file
		$problemContents = $@ if $@;
		$editErrors .= $problemContents;
		$currentSourceFilePath			=	"$problemPath.$editFileSuffix"; 
		$self->{currentSourceFilePath}	=	$currentSourceFilePath; 
	} elsif ($submit_button	eq 'Refresh' ) {
		# grab the problemContents from the form in order to save it to the tmp file
		# store tmp file name in the $self->currentSourceFilePath for use in body 
		
		$problemContents				=	$r->param('problemContents');
		$currentSourceFilePath			=	"$problemPath.$editFileSuffix";	
		$self->{currentSourceFilePath}	=	$currentSourceFilePath;
	} elsif ($submit_button eq 'Save') {
		# grab the problemContents from the form in order to save it to the permanent file
		# later we will unlink (delete) the temporary file
	 	# store permanent file name in the $self->currentSourceFilePath for use in body 
		
		$problemContents				=	$r->param('problemContents');
		$currentSourceFilePath			=	"$problemPath"; 		
		$self->{currentSourceFilePath}	=	$currentSourceFilePath;		
	} else {
		# give a warning
		die "Unrecognized submit command $submit_button";
	}
	
	# Handle the problem of line endings.  Make sure that all of the line endings.  Convert \r\n to \n
	$problemContents    =~    s/\r\n/\n/g;
	$problemContents    =~    s/\r/\n/g;
	
	# print changed pg files
	# FIXME  make sure that the permissions are set correctly!!!
	# Make sure that the warning is being transmitted properly.
	
	eval {
		local *OUTPUTFILE;
		open OUTPUTFILE, ">", $currentSourceFilePath
				or die "Failed to write to $currentSourceFilePath: $!";
		print OUTPUTFILE $problemContents;
		close OUTPUTFILE;
	};
	# record an error string for later use if there was a difficulty in writing to the file
	# FIXME is this string every inspected?
	
	my $openTempFileErrors = $@ if $@;
	
	if (  $openTempFileErrors)   {
	    
		$self->{openTempFileErrors}	= "Unable to write to $currentSourceFilePath: $openTempFileErrors";
		#diagnose errors:
		warn "Editing errors: $openTempFileErrors\n";
		warn "The file $currentSourceFilePath exists. \n " if -e $currentSourceFilePath; #FIXME 
		warn "The file $currentSourceFilePath cannot be found. \n " unless -e $currentSourceFilePath;
		warn "The file $currentSourceFilePath does not have write permissions. \n"
		                 if -e $currentSourceFilePath and not -w $currentSourceFilePath;
		
		
		
	} else {	
		# unlink the temporary file if there are no errors and the save button has been pushed
	    
		$self->{openTempFileErrors}	=	'';
		unlink("$problemPath.$editFileSuffix") if defined($submit_button) and $submit_button eq 'Save';		
	};
	
		
	# return values for use in the body subroutine
	$self->{problemPath}    =   $problemPath;
	$self->{displayMode}    =   $displayMode;
	$self->{problemSeed}    =   $problemSeed;
	
	# FIXME  there is no way to edit in a temporary file -- all editing takes place on disk!!!

	
	
}

sub path {
	my $self          = shift;
	my $set_id        = shift;
	my $problem_id    = shift;
	my $args          = $_[-1];
	
	my $ce = $self->{ce};
	my $root = $ce->{webworkURLs}->{root};
	my $courseName = $ce->{courseName};
	return $self->pathMacro($args,
		"Home"          => "$root",
		$courseName     => "$root/$courseName",
		'instructor'    => "$root/$courseName/instructor",
		'sets'          => "$root/$courseName/instructor/sets/",
		"set:$set_id"   => "$root/$courseName/instructor/sets/$set_id/",
		"problems"      => "$root/$courseName/instructor/sets/$set_id/problems",
		"problem:$problem_id"   => ''
	);
}
sub body {
	my $self = shift;
	
	# test area
	my $r       =   $self->{r};
	my $db      =   $self->{db};
	my $ce      =   $self->{ce};
	my $user    =   $r->param('user');
	my $key     =   $db->getKey($user)->key();
	
	
	################
	# Gathering info
	# What is needed
	#     $problemPath  -- 
	#     $formURL -- given by $r->uri
	#     $tmpProblemPath 
	my $problemPath 	= 	$self->{problemPath};

	
	

	
	

	my $header = "Problem Editor:  $problemPath";

	#########################################################################
	# Find the text for the problem, either in the tmp file, if it exists
	# or in the original file in the template directory
	#########################################################################
	my $problemContents = '';

	eval { $problemContents	=	WeBWorK::Utils::readFile($problemPath)  };  # try to read file
	$problemContents = $@ if $@;
	
			
			
	#########################################################################
	# Format the page
	#########################################################################
	# Define parameters for textarea
	# FIXME 
	# Should the seed be set from some particular user instance??
	# The mode list should be obtained from global.conf ultimately
	my $rows 		= 	20;
	my $columns		= 	80;
	my $mode_list 	= 	['plainText','formattedText','images'];
	my $displayMode	= 	$self->{displayMode};
	my $problemSeed	=	$self->{problemSeed};	
	my $uri			=	$r->uri;
	########################################################################
	# Define a link to view the problem
	#FIXME
	
	#########################################################################

	
	warn "Errors in the problem ".CGI::br().$self->{editErrors} if $self->{editErrors};

			   
	return CGI::p($header),
		#CGI::start_form("POST",$r->uri,-target=>'_problem'),  doesn't pass on the target parameter???
		qq!<form method="POST" action="$uri" enctype="application/x-www-form-urlencoded", target="_problem">!,
		$self->hidden_authen_fields,
		CGI::div(
		CGI::textfield(-name=>'problemSeed',-value=>$problemSeed),
		'Mode: ',
		CGI::popup_menu(-name=>'displayMode', -'values'=>$mode_list,
													 -default=>$displayMode),
		CGI::a(
			{-href=>'http://webwork.math.rochester.edu/docs/docs/pglanguage/manpages/',-target=>"manpage_window"},
			'Manpages',
			)
		),
		CGI::p(
			CGI::textarea(-name => 'problemContents', -default => $problemContents,
						  -rows => $rows, -columns => $columns, -override => 1,
			),
		),
		CGI::p(
			CGI::submit(-value=>'Refresh',-name=>'submit'),
			CGI::submit(-value=>'Save',-name=>'submit'),
#			$actionString
		),
		
		#CGI::a({-href=>$ce->{viewProblemURL},-target=>'_viewProblem'},'view problem'),
		CGI::end_form(),
#		"<p> the parameters passed are "  #FIXME -- debugging code
#		. join("<BR>", %{$r->param()}) . 
#		"</p> and the gatheredInfo is ",
#		"problemPath=$problemPath<br> formURL=".$r->uri . "<br>"   ,
#		"viewProblemURL ".$ce->{viewProblemURL}."<br>",
#		"problem_obj =". $ce->{problem_obj}."<br>",
#		"path_components ". $ce->{path_components}.'<br>',
# 		"hostname =$hostname<br>",
# 		"port =$port <br>",
# 		"uri = $uri <br>",
# 		"viewURL =".$ce->{viewURL}."<br>",
		 
	;


}



1;
