# Base class that all other mapping methods inherit from

package XrefMapper::Methods::ExonerateBasic;

use strict;

use File::Basename;
use IPC::Open3;

# Path to exonerate executable
#my $exonerate_path = "/usr/local/ensembl/bin/exonerate-0.9.0";
my $exonerate_path = "/software/ensembl/bin/exonerate-1.4.0";

sub new {

  my($class) = @_;

  my $self ={};
  bless $self,$class;
  $self->jobcount(0);

  return $self;

}

=head2 jobcount
 
  Arg [1]    : (optional) 
  Example    : $mapper->jobcount(1004);
  Description: Getter / Setter for number of jobs submitted. 
  Returntype : scalar
  Exceptions : none

=cut

sub jobcount {
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_jobcount} = $arg );
  return $self->{_jobcount};
}
 

=head2 run

  Arg[1]     : Query filename to pass to exonerate; this should be the XREF file.
  Arg[2]     : Target filename to pass to exonerate; this should be the ENSEMBL file.
  Example    : none
  Description: Run exonerate with default options.
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub run() {

  my ($self, $query, $target, $mapper) = @_;

  my $name = $self->submit_exonerate($query, $target, $mapper, $self->options());

  return $name;

}

=head2 options

  Args       : none
  Example    : none
  Description: Options to pass to exonerate. Override as appropriate.
  Returntype : List of strings.
  Exceptions : none
  Caller     : general

=cut

sub options() {

  return ();

}

=head2 submit_exonerate

  Args       : none
  Example    : none
  Description: Submit a *single* mapping job array to exonerate.
  Returntype : The name of the job array submitted to LSF. Can be used in depend job.
  Exceptions : none
  Caller     : general

=cut

sub submit_exonerate {

#  my ($self, $query, $target, $root_dir, $nofarm, @options) = @_;
  my ($self, $query, $target, $mapper, @options) = @_;


  my $root_dir = $mapper->core->dir;

  print "query $query\n" if($mapper->verbose);
  my $queryfile = basename($query);
  print "target $target\n" if($mapper->verbose);
  my $targetfile = basename($target);

  my $prefix = $root_dir . "/" . basename($query);
  $prefix =~ s/\.\w+$//;

  my ($ensembl_type) = $prefix =~ /.*_(dna|peptide)$/; # dna or prot
  my $options_str = join(" ", @options);

  my $unique_name = $self->get_class_name() . "_" . time();

  my $disk_space_needed = (stat($query))[7]+(stat($target))[7];

  $disk_space_needed /= 1024000; # convert to MB
  $disk_space_needed = int($disk_space_needed);
  $disk_space_needed += 1;
#  print "disk space needed = ".$disk_space_needed."\n";

  my $num_jobs = calculate_num_jobs($query);

  if(defined($mapper->nofarm)){
    my $output = $self->get_class_name() . "_" . $ensembl_type . "_1.map";
    my $cmd = <<EON;
$exonerate_path $query $target --showvulgar false --showalignment FALSE --ryo "xref:%qi:%ti:%ei:%ql:%tl:%qab:%qae:%tab:%tae:%C:%s\n" $options_str | grep '^xref' > $root_dir/$output
EON
    print "none farm command is $cmd\n" if($mapper->verbose);


    # write details of job to database
    
    my $sth = $mapper->xref->dbc->prepare("insert into process_status (status, date) values('mapping_submitted',now())");
    $sth->execute();
    $sth->finish;
    
    my $jobid = 1;
    if($ensembl_type eq "peptide"){
      $jobid = 2;
    }

    for( my $i=1; $i<=1; $i++){
      my $command = "$exonerate_path $query $target --showvulgar false --showalignment FALSE --ryo ".
	'"xref:%qi:%ti:%ei:%ql:%tl:%qab:%qae:%tab:%tae:%C:%s\n"'." $options_str | grep ".'"'."^xref".'"'." > $root_dir/$output";
      my $insert = "insert into mapping (job_id, type, command_line, percent_query_cutoff, percent_target_cutoff, method, array_size) values($jobid, '$ensembl_type', '$command',".
				       $self->query_identity_threshold.", ".$self->target_identity_threshold.", '".$self->get_class_name()."', $i)";
      
      $sth = $mapper->xref->dbc->prepare($insert);
      $sth->execute;
      $sth->finish;
      
      $sth = $mapper->xref->dbc->prepare("insert into mapping_jobs (root_dir, map_file, status, out_file, err_file, array_number, job_id) values (?,?,?,?,?,?,?)");
      
      my $map_file = $self->get_class_name()."_".$ensembl_type."_".$i.".map";
      my $out_file = "xref_0_".$ensembl_type.".".$jobid."-".$i.".out";
      my $err_file = "xref_0_".$ensembl_type.".".$jobid."-".$i.".err";
      $sth->execute($root_dir, $map_file, 'SUBMITTED', $out_file, $err_file, $i, $jobid);
    }
    $sth->finish;
    

    system($cmd);
    $self->jobcount(1);
    return "nofarm";
  }


  # array features barf if just one job 
  if($num_jobs == 1){
    $num_jobs++;
  }

  $self->jobcount($self->jobcount()+$num_jobs);



  my $output = $self->get_class_name() . "_" . $ensembl_type . "_" . "\$LSB_JOBINDEX.map";

  my @main_bsub = ( 'bsub', '-R' .'select[linux] -Rrusage[tmp='.$disk_space_needed.']',  '-J' . $unique_name . "[1-$num_jobs]%200", '-o', "$prefix.%J-%I.out", '-e', "$prefix.%J-%I.err");





  # Create actual execute script to be executed with LSF, and write to pipe
  my $main_job = <<EOF;
. /usr/local/lsf/conf/profile.lsf


$exonerate_path $query $target --querychunkid \$LSB_JOBINDEX --querychunktotal $num_jobs --showvulgar false --showalignment FALSE --ryo "xref:%qi:%ti:%ei:%ql:%tl:%qab:%qae:%tab:%tae:%C:%s\n" $options_str | grep '^xref' > $root_dir/$output

EOF



  # now submit it
  my $jobid = 0;

  eval {
    my $pid;
    my $reader;

    local *BSUB;
    local *BSUB_READER;

    if (($reader = open(BSUB_READER, '-|'))) {
      while (<BSUB_READER>) {

	if (/^Job <(\d+)> is submitted/) {
	  $jobid = $1;
	  print "LSF job ID for main mapping job: $jobid (job array with $num_jobs jobs)\n" if($mapper->verbose);
	}
      }
      close(BSUB_READER);
    } else {
      die("Could not fork : $!\n") unless (defined($reader));
      open(STDERR, ">&STDOUT");
      if (($pid = open(BSUB, '|-'))) {
	
	print BSUB $main_job;
	close BSUB;
	if ($? != 0) {
	  die("bsub exited with non-zero status - job not submitted\n");
	}
      } else {
	if (defined($pid)) {
	  exec(@main_bsub);
	  die("Could not exec bsub : $!\n");
	} else {
	  die("Could not fork : $!\n");
	}
      }
      exit(0);
    }
  };

  if ($@) {
    # Something went wrong
    warn("Job submission failed:\n$@\n");
    return 0;
  }
  else{
    # write details of job to database
    my $command = "$exonerate_path $query $target --querychunkid \$LSB_JOBINDEX --querychunktotal $num_jobs --showvulgar false --showalignment FALSE --ryo ".
      '"xref:%qi:%ti:%ei:%ql:%tl:%qab:%qae:%tab:%tae:%C:%s\n"'." $options_str | grep ".'"'."^xref".'"'." > $root_dir/$output";

    my $sth = $mapper->xref->dbc->prepare("insert into process_status (status, date) values('mapping_submitted',now())");
    $sth->execute();
    $sth->finish;

    my $insert = "insert into mapping (job_id, type, command_line, percent_query_cutoff, percent_target_cutoff, method, array_size) values($jobid, '$ensembl_type', '$command',".
				       $self->query_identity_threshold.", ".$self->target_identity_threshold.", '".$self->get_class_name()."', $num_jobs)";


    $sth = $mapper->xref->dbc->prepare($insert);
    $sth->execute;
    $sth->finish;

    $sth = $mapper->xref->dbc->prepare("insert into mapping_jobs (root_dir, map_file, status, out_file, err_file, array_number, job_id) values (?,?,?,?,?,?,?)");
    
    for( my $i=1; $i<=$num_jobs; $i++){
      my $map_file = $self->get_class_name()."_".$ensembl_type."_".$i.".map";
      my $out_file = "xref_0_".$ensembl_type.".".$jobid."-".$i.".out";
      my $err_file = "xref_0_".$ensembl_type.".".$jobid."-".$i.".err";
      $sth->execute($root_dir, $map_file, 'SUBMITTED', $out_file, $err_file, $i, $jobid);
    }
    $sth->finish;
    
  }
  
  return $unique_name;

}

=head2 calculate_num_jobs

  Args       : Query file name
  Example    : none
  Description: Calculate the number of LSF jobs to submit based on the size of the query file.
  Returntype : The number of jobs.
  Exceptions : none
  Caller     : general

=cut

sub calculate_num_jobs {

  my $query = shift;

  my $bytes_per_job = 250000;

  my $size = (stat $query)[7];
  if( $size == 0 ){ return 0 }
  return int($size/$bytes_per_job) || 1;

}

# Get class name from fully-qualified object name
# e.g. return ExonerateBasic from XrefMapper::Methods::ExonerateBasic=HASH(Ox12113c0)

sub get_class_name() {

  my $self = shift;

  my $module_name = ref($self);

  my @bits = split(/::/, $module_name);

  return $bits[-1];

}

# Check if any .err files exist that have non-zero size;
# this indicates that something has gone wrong with the exonerate run

sub check_err {

  my ($self, $dir) = @_;

  foreach my $err (glob("$dir/*.err")) {

    print "\n\n*** Warning: $err has non-zero size; may indicate problems with exonerate run\n\n\n" if (-s $err);

  }
}

# Percentage identity that query (xref) must match to be considered.

sub query_identity_threshold {

  return 0;

}


# Percentage identity that target (ensembl) must match to be considered.

sub target_identity_threshold {

  return 0;

}

1;

