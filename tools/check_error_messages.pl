#! /usr/bin/perl -w
#
# check_error_messages.pl
#
# This perl script extracts error or warning messages from the emaj--next_version.sql source file.
# It then extracts the error or warning messages from the regression tests result files,
# and finaly displays the messages from the source file that are not covered by the regression tests.

use warnings; use strict;

# The 3 variables below are to be customized
  my $dir = "/home/postgres/proj/emaj";
  my $ficSrc = $dir."/sql/emaj--next_version.sql";
  my $dirOut = $dir."/test/96/results";

# Variables used to process the source code
  my $line;
  my $lineNumber = 0;
  my $lineNumberInFnct = 0;
  my $schema;
  my $fnctName;
  my $msgType;
  my $msg;
  my %msgs = ();
  my %msgRegexp = ();
  my %msgCount = ();
  my $nbException = 0;
  my $nbWarning = 0;
  my $regexp;

# Variables used to process the regression test output results
  my $res;
  my $script;
  my $fnctId;
  my $nbFound;
  my $lastFound;
  my $isTittleDisplayed = 0;

# initialisation
  print ("------------------------------------------------------------\n");
  print ("  Analysis of error messages generated by regression tests  \n");
  print ("------------------------------------------------------------\n");
  open (FICSRC,$ficSrc) || die ("Error in opening ".$ficSrc." file\n");

# scan and process input file
  while (<FICSRC>){
    $line = $_; $lineNumber++; $lineNumberInFnct++;
# delete the comment part of the line, if any (this does not properly process -- pattern inside literal of object names, but this is enough for now)
    $line =~ s/--.*//;
# detection of function or do block start
    if ($line =~ /^CREATE OR REPLACE FUNCTION\s+(.*?)\.(.*?)\(/) {
      $schema = $1; $fnctName = $2; $lineNumberInFnct = 1;
    }
    if ($line =~ /^DO /) {
      $schema = ''; $fnctName = 'do'; $lineNumberInFnct = 1;
    }
# detection of warning or error messages
    if ($line =~ /RAISE (EXCEPTION|WARNING)\s+'(.*?)'(\s|;|,)/) {
      $msgType = $1; $msg = $2;
      next if ($msg eq '');
      $nbException++ if ($msgType eq 'EXCEPTION');
      $nbWarning++ if ($msgType eq 'WARNING');
# transform the message into a regexp
      $regexp = $msg;
      $regexp =~ s/\./\\\./g;
      $regexp =~ s/\(/\\\(/g;
      $regexp =~ s/\)/\\\)/g;
      $regexp =~ s/''/'/g;
      $regexp =~ s/%/.*?/g;
# register the message and its regexp
      if ($fnctName eq 'do') {
        $msgs{"$fnctName:$lineNumber"} = "$msgType:$msg";
        $msgRegexp{"$fnctName:$lineNumber"} = "$msgType:$regexp";
        $msgCount{"$fnctName:$lineNumber"} = 0;
      } else {
        $msgs{"$schema.$fnctName:$lineNumberInFnct"} = "$msgType:$msg";
        $msgRegexp{"$schema.$fnctName:$lineNumberInFnct"} = "$msgType:$regexp";
        $msgCount{"$schema.$fnctName:$lineNumberInFnct"} = 0;
      }
    }
  }

# complete the source processing
  close (FICSRC);

# search for error messages in regression tests results, using grep
  $res = `grep -P 'ERROR:|WARNING:' $dirOut/*.out`;
# split the output into lines for analysis
  $msg = '';
  while ($res =~ /^(.+?)\n(.*)/sm) {
    $line = $1;
    $res = $2;
# get interresting pieces from each line
    if ($line =~ /^.*\/(.+?)\.out:(ERROR|WARNING|psql):\s*(\S.*)/ ||             # line from postgres
        $line =~ /^.*\/(.+?)\.out:PHP Warning.*?(ERROR|WARNING):\s*(\S.*)/) {    # line ERROR or WARNING from PHP
# one interesting line identified
      $script = $1.'.sql';
      $msgType = $2;
      $line = $3;
      if ($1 ne 'beforeMigLoggingGroup' && $1 ne 'install_previous' && $1 ne 'install_upgrade' && $1 !~ /psql/i) {
# ignore lines from the scripts that process code from the previous E-Maj version
        if ($msgType eq 'ERROR' || $msgType eq 'WARNING') {
          $msg = $line;
          $nbFound = 0;
# look for this message in the recorded messages from the source
          while (($fnctId, $regexp) = each(%msgRegexp)) {
            if (($msgType eq 'ERROR' && ("EXCEPTION:".$msg) =~ $regexp) || ($msgType eq 'WARNING' && ("WARNING:".$msg) =~ $regexp)) {
              $nbFound++;
              $lastFound = $fnctId;
            }
          }
# uncomment the 3 following lines to check the error messages from .out that are not recognized as coming from the E-Maj source file (could be an option !)
#          if ($nbFound == 0) {
#            print "Nothing found for : Script $script, Message $msg \n";
#          }
          if ($nbFound > 1) {
            print "!!! In script $script, the message '$msg' has been found at several places in the source\n";
          }
          if ($nbFound >= 1) {
# at least one place in the source fit the message read from the regression tests output, so increment usage counter (of the last found, if several)
            $msgCount{"$lastFound"}++;
          }
        }
      }
    } else {
      if ($line !~ /^.*\/(.+?)\.out:\\!(.*)/) {     # lines with \! (shell command calls) are not processed
# unexpected problem with the line analysis
        die "Unrecognized line:\n$line\n";
      }
    }
  }

# the analysis of regression test output files is completed, display the results
  print "The source file contains $nbException exceptions and $nbWarning warning messages.\n";
  while (($fnctId, $nbFound) = each(%msgCount)) {
    if ($nbFound == 0) {
# do not report some messages known to not be present in the regression test suite
                            # installation conditions that are not met during the tests
      if ($msgs{$fnctId} ne 'EXCEPTION:E-Maj installation: the current user (%) is not a superuser.'
       && $msgs{$fnctId} ne 'EXCEPTION:E-Maj installation: the current postgres version (%) is too old for E-Maj.'
       && $msgs{$fnctId} ne 'WARNING:E-Maj installation: as the max_prepared_transactions parameter value (%) on this cluster is too low, no parallel rollback is possible.'
       && $msgs{$fnctId} ne 'EXCEPTION:The current postgres version (%) is not compatible with E-Maj.'
                            # internal errors (errors that should never appear and that would due to coding error)
       && $msgs{$fnctId} ne 'EXCEPTION:_drop_log_schema: internal error (schema "%" does not exist).'
       && $msgs{$fnctId} ne 'EXCEPTION:emaj_reset_group: internal error (group "%" is empty).'
#       && $msgs{$fnctId} ne 'EXCEPTION:_rlbk_tbl: internal error (at least one list is NULL (columns list = %, pk columns list = %, conditions list = %).'
                            # execution conditions that cannot be reproduced without parallelism
       && $msgs{$fnctId} ne 'EXCEPTION:_lock_groups: too many (5) deadlocks encountered while locking tables of group "%".'
       && $msgs{$fnctId} ne 'EXCEPTION:_rlbk_session_lock: too many (5) deadlocks encountered while locking tables for groups "%".'
       && $msgs{$fnctId} ne 'EXCEPTION:_rlbk_start_mark: % Please retry.'
                            # cases that are tested in the misc.sql script but without displaying the error messages 
                            # because they contain timestamp fields that are not stable though test executions
       && $msgs{$fnctId} ne 'EXCEPTION:emaj_log_stat_group: mark id for "%" (% = %) is greater than mark id for "%" (% = %).'
       && $msgs{$fnctId} ne 'EXCEPTION:emaj_detailed_log_stat_group: mark id for "%" (% = %) is greater than mark id for "%" (% = %).'
       && $msgs{$fnctId} ne 'EXCEPTION:emaj_snap_log_group: mark id for "%" (% = %) is greater than mark id for "%" (% = %).'
         ) {
# report the other messages
        if (! $isTittleDisplayed) {
          print "The coded error/warning messages not found in regression test outputs:\n";
          $isTittleDisplayed = 1;
        }
        print "  Id = $fnctId ; message = $msgs{$fnctId}\n";
      }
    }
  }
  if (! $isTittleDisplayed) {
    print "No unexpected uncovered error or warning messages\n";
  }
  print "Analysis Completed.\n"
# end of the script

