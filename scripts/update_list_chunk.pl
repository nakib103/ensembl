#!/usr/local/bin/perl

=head1 NAME

Update

=head1 SYNOPSIS
 
  update.pl

=head1 DESCRIPTION

This script updates a recipient database by checking its donor database

=head1 OPTIONS

    -host      host name for database (gets put as host= in locator)

    -port      For RDBs, what port to connect to (port= in locator)

    -dbname    For RDBs, what name to connect to (dbname= in locator)

    -dbuser    For RDBs, what username to connect as (dbuser= in locator)

    -dbpass    For RDBs, what password to use (dbpass= in locator)

    -help      Displays script documentation with PERLDOC
    
    -nowrite   Runs entire script without writing in recipient

    -verbose   Gets all the print STDERR for testing purposes

=cut

use Bio::EnsEMBL::Analysis::UpdateManager;

use strict;
use Getopt::Long;
use vars qw(@ISA);

@ISA = qw(Bio::Root::Object);

my $fdbtype = 'rdb';
my $fhost   = 'obi-wan';
my $fport   = '410000';
my $fdbname = 'ensembl';
my $fdbuser = 'ensro';
my $fpass = undef;
my $tdbtype = 'rdb';
my $thost   = 'localhost';
my $tport   = '410000';
my $tdbname = 'ensembl';
my $tdbuser = 'root';
my $tpass = undef;
my $adbname = 'ens_archive';
my $module = "Bio::EnsEMBL::DBSQL::Obj";

my $help;
my $nowrite;
my $verbose;
my $slice;

&GetOptions( 
	     'fdbtype:s'  => \$fdbtype,
	     'fhost:s'    => \$fhost,
	     'fport:n'    => \$fport,
	     'fdbname:s'  => \$fdbname,
	     'fdbuser:s'  => \$fdbuser,
	     'fpass:s'    => \$fpass,
	     'tdbtype:s'  => \$tdbtype,
	     'thost:s'    => \$thost,
	     'tport:n'    => \$tport,
	     'tdbname:s'  => \$tdbname,
	     'tdbuser=s'  => \$tdbuser,
	     'tpass:s'    => \$tpass,
             'adbname:s'  => \$adbname,
	     'module=s'  => \$module,
	     'h|help'    => \$help,
	     'nowrite'   => \$nowrite,
	     'slice:s'   => \$slice,
	     'v|verbose' => \$verbose
	     );


$module = "Bio::EnsEMBL::DBSQL::Obj";

if ($help) {
    exec('perldoc', $0);
}

my $to_locator       = make_locator_string($tdbtype,$module,$thost,$tport,$tdbname,$tdbuser,$tpass);
my $tdb              = new Bio::EnsEMBL::DBLoader($to_locator);
my $from_locator     = $tdb->get_donor_locator;
my $arc_locator      = "Bio::EnsEMBL::DBArchive::Obj//host=$thost;port=$tport;dbname=$adbname;user=$tdbuser;pass=$tpass";

my $last_offset      = $tdb->get_last_update_offset;
my $now_offset       = time - 30*60;    # This should be something different

print STDERR "From/to times $last_offset $now_offset\n";

$| = 1;

if ($last_offset > $now_offset) {
    print "Time of last_offset update more recent than now-offset, exiting!\n";
    exit;
}

my $update_manager   = new Bio::EnsEMBL::Analysis::UpdateManager(-fromlocator => $from_locator,
								 -tolocator   => $to_locator,
								 -arclocator  => $arc_locator,
								 -fromtime    => $last_offset,
								 -totime      => $now_offset,
								 );

$update_manager->nowrite  ($nowrite);
$update_manager->verbose  ($verbose);
$update_manager->chunksize(20);
$update_manager->update;



sub make_locator_string {
    my ($type,$module,$host,$port,$dbname,$dbuser,$dbpass) = @_;

    if ($type eq "rdb") {
	return 	"$module/host=$host;port=$port;dbname=$dbname;user=$dbuser;pass=$dbpass";
    } elsif ($type eq "timdb") {
	return "Bio::EnsEMBL::TimDB::Obj";
    } else {
	die "Database type [$type] not recognised\n";
    }
}


