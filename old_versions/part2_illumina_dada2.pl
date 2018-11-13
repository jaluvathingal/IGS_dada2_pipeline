#!/usr/bin/env perl

=head1 NAME

  part2_illumina_dada2.pl  

=head1 DESCRIPTION

  Given a comma-separated list of Illumina amplicon runs and the variable region for the amplicons,
  and assuming these runs are also the names of the directories containing sequence abundance tables 
  written by R(dada2) saveRDS(seqtab, "dada2_abundance_table.rds") for those runs, this script will:

    -Read in each .rds file to R
    -Remove chimeras
    -Write a chimera-removed abundance table
    -Assign taxonomy via SILVA
    -Assign taxonomy via RDP
    -Classify sequences with PECAN

    -Default: 
      Classify ASVs with PECAN and SILVA
      For count table, write only PECAN classifications using vaginal merging rules.

  *** If providing multiple runs, this script cannot be q-submitted at this time.***
  *** Run from qlogin within the project directory produced in Part 1.***
  *** Recommended running w/multiple runs:

      From RHEL5:
      screen
      qlogin -P jravel-lab -l mem_free=500M -q interactive.q
      export LD_LIBRARY_PATH=/usr/local/packages/gcc/lib64
      source /usr/local/packages/usepackage/share/usepackage/use.bsh
      use python-2.7
      use qiime
      part2_illumina_dada2.pl -i <comma-separated-input-run-names> -v <variable-region> -p <project-ID>

      You can close the terminal at any time. 
      To return to this process the next time you login simply type:
      screen -r

=head1 SYNOPSIS

  part2_illumina_dada2.pl -i <input-run-names> -v <variable-region> -p <project-ID>

=head1 OPTIONS

=over

=item B<--input-run-names, -i>
  Comma-separated list of input run names (directories)

=item B<--desire-pecan-models, -v>
  V4 or V3V4 or ITS

=item B<--project-ID, -p>
  Provide the project ID

=item B<--notVaginal, --not-vaginal>
  optional flag. Use when project is NOT
  just vaginal sequences.

=item B<--pecan-silva, --pecan+silva>
  optional flag. Use when pecan+silva taxonomy
  is desired. 
  V3V4 Default: PECAN only
  V4 Default: SILVA only

=item B<-h|--help>
  Print help message and exit successfully.

=back

=head1 EXAMPLE

  cd /local/scratch/MM
  part2_illumina_dada2.pl -i MM_01,MM_03,MM_05,MM_21 -v V3V4 -p MM
  
=cut

use strict;
use warnings;
use Pod::Usage;
use English qw( -no_match_vars );
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev pass_through);
use Cwd qw(abs_path);
use File::Temp qw/ tempfile /;
#use Email::MIME;
#use Email::Sender::Simple qw(sendmail);

$OUTPUT_AUTOFLUSH = 1;

####################################################################
##                             OPTIONS
####################################################################

GetOptions(
  "input-runs|i=s"        => \my $inRuns,
  "variable-region|v=s"   => \my $region,
  "project-ID|p=s"        => \my $project,
  "overwrite|o=s"         => \my $overwrite,
  "help|h!"               => \my $help,
  "debug"                 => \my $debug,
  "dry-run"               => \my $dryRun,
  "skip-err-thld"         => \my $skipErrThldStr,
  "notVaginal"            => \my $notVaginal,
  "pecan-silva"           => \my $pecanSilva,
  )

  or pod2usage(verbose => 0,exitstatus => 1);

if ($help)
{
  pod2usage(verbose => 2,exitstatus => 0);
  exit 1;
}

local $ENV{LD_LIBRARY_PATH} = "/usr/local/packages/gcc/lib64";
my $R = "/usr/local/packages/r-3.4.0/bin/R";

if (!$region)
{
  print "Please provide a variable region (-v), V3V4 or V4\n";
  pod2usage(verbose => 2,exitstatus => 0);
  exit 1;
}
my $models;
if ($region eq 'V3V4')
{
  $models = "/local/projects-t2/jholm/PECAN/v1.0/V3V4/merged_models/";
}
if ($region eq 'V4')
{
  print "Using SILVA taxonomy only\n";
}
if ($region eq 'V3V4' && !$models)
{
  print "Please provide a valid variable region\n\n";
  pod2usage(verbose => 2,exitstatus => 0);
  exit 1;
}

if (!$project)
{
  print "Please provide a project name\n\n";
  pod2usage(verbose => 2,exitstatus => 0);
  exit 1;
}

if(!$inRuns)
{
  print "Please provide (a) run ID(s)\n\n";
  pod2usage(verbose => 2,exitstatus => 0);
  exit 1;
}

####################################################################
##                               MAIN
####################################################################

##split the list of runs to an array
my @runs = split(",",$inRuns);

my $log = "$project"."_part2_16S_pipeline_log.txt";
open LOG, ">$log" or die "Cannot open $log for writing: $OS_ERROR";
print LOG "This file logs the progress of ". scalar(@runs) ." runs for $project 16S amplicon sequences through the illumina_dada2.pl pipeline.\n";

my $cmd = "rm -f *-dada2_abundance_table.rds";
print "\tcmd=$cmd\n" if $dryRun || $debug;
system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;

##loop over array to copy the file to the main current working directory
## using the array string to also add a name
if (scalar(@runs) > 1)
{
  print "---Copying " . scalar(@runs) . " abundance tables to this directory & combining\n";
  print LOG "---Copying " . scalar(@runs) . " abundance tables to this directory & combining\n";
  print LOG "Runs:\n";
}
else
{
  print "---Copying 1 abundance table to this directory\n";
  print "---Proceeding to chimera removal for 1 run\n";
  print LOG "---Copying 1 abundance table to this directory\n";
  print LOG "---Proceeding to chimera removal for 1 run\n";
  print LOG "Run:\n";
}

foreach my $i (@runs)
{
  print LOG "$i\n";
  my $currTbl = $i ."/dada2_abundance_table.rds";
  my $newTbl = $project ."_". $i . "-dada2_abundance_table.rds";
  my $cmd = "cp $currTbl $newTbl";
  print "\tcmd=$cmd\n" if $dryRun || $debug;
  system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
  print LOG "$cmd\n";

  my $currStats = $i."/dada2_part1_stats.txt";
  my $newStats = $project ."_". $i . "-dada2_part1_stats.txt";
  $cmd = "cp $currStats $newStats";
  print "\tcmd=$cmd\n" if $dryRun || $debug;
  system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
  print LOG "$cmd\n";
}

# my $catStats = $project ."_". "dada2_part1_stats.txt";
# $cmd = "cat *-dada2_part1_stats.txt > $catStats";
# print "\tcmd=$cmd\n" if $dryRun || $debug;
# system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
# print LOG "$cmd\n";

my $abundance = "all_runs_dada2_abundance_table.csv";
my $projabund = $project ."_". $abundance;


print "---Performing chimera removal on merged tables and classifying amplicon sequence variants (ASVs)\n";
print LOG "---Performing chimera removal on merged tables and classifying amplicon sequence variants (ASVs)\n";
dada2_combine_and_classify($inRuns);

print "---Merged, chimera-removed abundance tables written to all_runs_dada2_abundance_table.csv\n";
print "---ASVs classified via silva written to silva_classification.csv\n";
print "---ASVs classified via RDP written to rdp_classification.csv\n";
print "---Final ASVs written to all_runs_dada2_ASV.fasta for classification via PECAN\n";
print "---dada2 completed successfully\n";

print LOG "---Merged, chimera-removed abundance tables written to all_runs_dada2_abundance_table.csv\n";
print LOG "---ASVs classified via silva written to silva_classification.csv\n";
print LOG "---ASVs classified via RDP written to rdp_classification.csv\n";
print LOG "---Final ASVs written to all_runs_dada2_ASV.fasta for classification via PECAN\n";
print LOG "---dada2 completed successfully\n";

print "---Renaming dada2 files for project\n";
print LOG "---Renaming dada2 files for project\n";
$cmd = "mv $abundance $projabund";
print "\tcmd=$cmd\n" if $dryRun || $debug;
system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
print LOG "$cmd\n";

print "---Renaming SILVA classification file for project\n";
print LOG "---Renaming SILVA classification file for project\n";
my $silva = "silva_classification.csv";
my $projSilva = $project ."_". $silva;
$cmd = "mv $silva $projSilva";
print "\tcmd=$cmd\n" if $dryRun || $debug;
system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
print LOG "$cmd\n";

my $projpecan = $project ."_"."MC_order7_results.txt";

if ($region eq 'V3V4')
{
  print "---Classifying ASVs with $region PECAN models (located in $models)\n";
  print LOG "---Classifying ASVs with $region PECAN models (located in $models)\n";
  my $fasta;
  $fasta = "all_runs_dada2_ASV.fasta";

  $cmd = "/local/projects/pgajer/devel/MCclassifier/bin/classify -d $models -i $fasta -o .";
  print "\tcmd=$cmd\n" if $dryRun || $debug;
  system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;

  my $pecan = "MC_order7_results.txt";

  $cmd = "mv $pecan $projpecan";
  print "\tcmd=$cmd\n" if $dryRun || $debug;
  system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
}

#### APPLY PECAN+SILVA CLASSIFICATIONS TO COUNT TABLE (V3V4) ####
#################################################################
if ($pecanSilva)
{
  if ($notVaginal) 
  {
    $cmd = "/home/jholm/bin/combine_tx_for_ASV.pl -p $projpecan -s $projSilva -c $projabund";
    print "\tcmd=$cmd\n" if $dryRun || $debug;
    system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
  }
  else
  {
    $cmd = "/home/jholm/bin/combine_tx_for_ASV.pl -p $projpecan -s $projSilva -c $projabund --vaginal";
    print "\tcmd=$cmd\n" if $dryRun || $debug;
    system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
  }
}
#### APPLY PECAN-ONLY CLASSIFICATIONS TO COUNT TABLE (V3V4) ####
################################################################
else
{
  if ($notVaginal) 
  {
    $cmd = "/home/jholm/bin/PECAN_tx_for_ASV.pl -p $projpecan -c $projabund";
    print "\tcmd=$cmd\n" if $dryRun || $debug;
    system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
  }
  else
  {
    $cmd = "/home/jholm/bin/PECAN_tx_for_ASV.pl -p $projpecan -c $projabund --vaginal";
    print "\tcmd=$cmd\n" if $dryRun || $debug;
    system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
  }
}

#### APPLY SILVA-ONLY CLASSIFICATIONS TO COUNT TABLE (V4) ####
##############################################################
if ($region eq 'V4')
{
  print "---Classifying ASVs with $region with SILVA only\n";
  print LOG "---Classifying ASVs with $region with SILVA only\n";
  $cmd = "/home/jholm/bin/combine_tx_for_ASV.pl -s $projSilva -c $projabund";
  print "\tcmd=$cmd\n" if $dryRun || $debug;
  system($cmd) == 0 or die "system($cmd) failed with exit code: $?" if !$dryRun;
}

# my $finalStats = $project . "_" . "dada2_final_stats.txt";
# my $part2Stats = "dada2_part2_stats.txt";
# my %part1 = readTbl($catStats);
# my %part2 = readTbl($part2Stats);
# open OUT, ">$finalStats" or die "Cannot open $finalStats for writing: $OS_ERROR";
# print OUT "SampleID\tInput\tFiltered\tMerged\tNonChimeric\n";
# foreach my $x (%part1)
# {
#   my $p1 = $part1{$x};
#   my $p2 = $part2{$x};
#   print "Combining dada2 stats for $x\n";
#   if (defined $p2 )
#   {
#     print OUT "$x\t$p1\t$p2\n";
#   }
#   elsif (!defined $p1)
#   {
#     print LOG "$x not present in $catStats\n";
#   }
# }
# close OUT;

my $final_merge = glob("*_taxa_only_merged.csv");
my $final_taxa_only = glob("*_taxa_only.csv");
my $final_ASV_taxa = glob("*_w_taxa.csv");

print LOG "---Final files succesfully produced!\n";
print LOG "Final merged read count table: $final_merge\nFinal unmerged taxa table: $final_taxa_only\nFinal ASV table with taxa: $final_ASV_taxa\nFinal ASV count table: $projabund\nASV sequences: all_runs_dada2_ASV.fasta\n"; #Read survival stats: $finalStats\n";
close LOG;



####################################################################
##                               SUBS
####################################################################

sub readTbl{

  my $file = shift;

  if ( ! -f $file )
  {
    warn "\n\n\tERROR in readTbl(): $file does not exist";
    print "\n\n";
    exit 1;
  }

  my %tbl;
  open IN, "$file" or die "Cannot open $file for reading: $OS_ERROR\n";
  foreach (<IN>)
  {
    chomp;
    my ($id, $t) = split(/\s+/,$_);
    $tbl{$id} = $t;
  }
  close IN;

  return %tbl;
}
sub dada2_combine_and_classify
{
  my ($inRuns) = shift;

  my $Rscript = qq~

library("dada2")
packageVersion("dada2")
path<-getwd()

## list all of the files matching the pattern
tables<-list.files(path, pattern="-dada2_abundance_table.rds", full.names=TRUE)
stats<-list.files(path, pattern="-dada2_part1_stats.txt", full.names=TRUE)

## get the run names using splitstring on the tables where - exists
sample.names <- sapply(strsplit(basename(tables), "-"), `[`, 1)
##sample.names
##names(tables) <- sample.names

runs <- vector("list", length(sample.names))
names(runs) <- sample.names
for(run in tables) {
  cat("Reading in:", run, "\n")
  runs[[run]] <- readRDS(run)
}

runstats <- vector("list", length(sample.names))
names(runstats) <- sample.names
for(run in stats) {
  cat("Reading in:", run, "\n")
  runstats[[run]] <- read.delim(run, )
}

unqs <- unique(c(sapply(runs, colnames), recursive=TRUE))
n<-sum(unlist(lapply(X=runs, FUN = nrow)))
st <- matrix(0L, nrow=n, ncol=length(unqs))
rownames(st) <- c(sapply(runs, rownames), recursive=TRUE)
colnames(st) <- unqs
for(sti in runs) {
  st[rownames(sti), colnames(sti)] <- sti
}
st <- st[,order(colSums(st), decreasing=TRUE)]

##st.all<-mergeSequenceTables(runs)
# Remove chimeras
seqtab <- removeBimeraDenovo(st, method="consensus", multithread=TRUE)
# Assign taxonomy
silva <- assignTaxonomy(seqtab, "/home/jholm/bin/silva_nr_v128_train_set.fa.gz", multithread=TRUE)
# Write to disk
saveRDS(seqtab, "all_runs_dada2_abundance_table.rds") # CHANGE ME to where you want sequence table saved
write.csv(seqtab, "all_runs_dada2_abundance_table.csv", quote=FALSE)
write.csv(silva, "silva_classification.csv", quote=FALSE)

fc = file("all_runs_dada2_ASV.fasta")
fltp = character()
for( i in 1:ncol(seqtab))
{
  fltp <- append(fltp, paste0(">", colnames(seqtab)[i]))
  fltp <- append(fltp, colnames(seqtab)[i])
}
writeLines(fltp, fc)
rm(fltp)
close(fc)

track<-as.matrix(rowSums(seqtab))
colnames(track) <- c("nonchimeric")
write.table(track, "dada2_part2_stats.txt", quote=FALSE, append=FALSE, sep="\t", row.names=TRUE, col.names=TRUE)
 ~;
run_R_script( $Rscript );
}

sub run_R_script {

  my $Rscript = shift;

  my $outFile = "rTmp.R";
  open OUT, ">$outFile",  or die "cannot write to $outFile: $!\n";
  print OUT "$Rscript";
  close OUT;

  #local $ENV{LD_LIBRARY_PATH} = "/usr/local/packages/gcc/lib64";
  #system($cmd) == 0 or die "system($cmd) failed:$?\n";
  my $cmd = "$R CMD BATCH $outFile";
  system($cmd) == 0 or die "system($cmd) failed:$?\n";

  my $outR = $outFile . "out";
  open IN, "$outR" or die "Cannot open $outR for reading: $OS_ERROR\n";
  my $exitStatus = 1;

  foreach my $line (<IN>)
  {
    if ($line =~ /learnErrors/ )
    {
      next;
    }
    elsif ($line =~ /Error/ )
    {
      print "R script crashed at\n$line";
      print "check $outR for details\n";
      $exitStatus = 0;
      exit;
    }
  }
  close IN;
}
exit 0;