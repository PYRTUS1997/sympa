# Upgrade.pm - This module gathers all subroutines used to upgrade Sympa data structures
#<!-- RCS Identication ; $Revision$ --> 

#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package Upgrade;

use strict;

#use Carp; # currently not used
use POSIX qw(strftime);
# tentative
use Data::Dumper;
use File::Copy::Recursive;

use Site;
#use Conf; # used in Site
#use Log; # used in Conf
#use Sympa::Constants; # used in Conf - confdef
#use SDM; # used in Conf

## Return the previous Sympa version, ie the one listed in data_structure.version
sub get_previous_version {
    my $version_file = Site->etc . '/data_structure.version';
    my $previous_version;
    
    if (-f $version_file) {
	unless (open VFILE, $version_file) {
	    &Log::do_log('err', "Unable to open %s : %s", $version_file, $!);
	    return undef;
	}
	while (<VFILE>) {
	    next if /^\s*$/;
	    next if /^\s*\#/;
	    chomp;
	    $previous_version = $_;
	    last;
	}
	close VFILE;
	
	return $previous_version;
    }
    
    return undef;
}

sub update_version {
    my $version_file = Site->etc . '/data_structure.version';

    ## Saving current version if required
    unless (open VFILE, ">$version_file") {
	&Log::do_log('err', "Unable to write %s ; sympa.pl needs write access on %s directory : %s", $version_file, Site->etc, $!);
	return undef;
    }
    print VFILE "# This file is automatically created by sympa.pl after installation\n# Unless you know what you are doing, you should not modify it\n";
    printf VFILE "%s\n", Sympa::Constants::VERSION;
    close VFILE;
    
    return 1;
}


## Upgrade data structure from one version to another
sub upgrade {
    Log::do_log('debug3', '(%s, %s)', @_);
    my ($previous_version, $new_version) = @_;

    if (&tools::lower_version($new_version, $previous_version)) {
	&Log::do_log('notice', 'Installing  older version of Sympa ; no upgrade operation is required');
	return 1;
    }

    ## Check database connectivity and probe database
    unless (SDM::check_db_connect('just_try') and SDM::probe_db()) {
	Log::do_log('err',
	    'Database %s defined in sympa.conf has not the right structure or is unreachable. verify db_xxx parameters in sympa.conf',
	    Site->db_name
	);
	return undef;
    }

    ## Always update config.bin files while upgrading
    &Conf::delete_binaries();
    ## Always update config.bin files while upgrading
    ## This is especially useful for character encoding reasons
    Log::do_log('notice',
	'Rebuilding config.bin files for ALL lists...it may take a while...');
    my $all_lists = List::get_lists('Site', {'reload_config' => 1});

    ## Empty the admin_table entries and recreate them
    &Log::do_log('notice','Rebuilding the admin_table...');
    &List::delete_all_list_admin();
    foreach my $list (@$all_lists) {
	$list->sync_include_admin();
    }

    ## Migration to tt2
    if (&tools::lower_version($previous_version, '4.2b')) {

	&Log::do_log('notice','Migrating templates to TT2 format...');	
	
	my $tpl_script = Sympa::Constants::SCRIPTDIR . '/tpl2tt2.pl';
	unless (open EXEC, "$tpl_script|") {
	    &Log::do_log('err', "Unable to run $tpl_script");
	    return undef;
	}
	close EXEC;
	
	Log::do_log('notice', 'Rebuilding web archives...');
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    next unless %{$list->web_archive}; #FIXME: always success
	    my $file = Site->queueoutgoing.'/.rebuild.'.$list->get_id();

	    unless (open REBUILD, ">$file") {
		&Log::do_log('err','Cannot create %s', $file);
		next;
	    }
	    print REBUILD ' ';
	    close REBUILD;
	}	
    }
    
    ## Initializing the new admin_table
    if (&tools::lower_version($previous_version, '4.2b.4')) {
	Log::do_log('notice', 'Initializing the new admin_table...');
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    $list->sync_include_admin();
	}
    }

    ## Move old-style web templates out of the include_path
    if (&tools::lower_version($previous_version, '5.0.1')) {
	&Log::do_log('notice','Old web templates HTML structure is not compliant with latest ones.');
	&Log::do_log('notice','Moving old-style web templates out of the include_path...');

	my @directories;

	if (-d Site->etc . '/web_tt2') {
	    push @directories, Site->etc . '/web_tt2';
	}

	## Go through Virtual Robots
	foreach my $vr (@{Robot::get_robots()}) {
	    if (-d $vr->etc . '/web_tt2') {
		push @directories, $vr->etc . '/web_tt2';
	    }
	}

	## Search in V. Robot Lists
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    if (-d $list->dir . '/web_tt2') {
		push @directories, $list->dir . '/web_tt2';
	    }	    
	}

	my @templates;

	foreach my $d (@directories) {
	    unless (opendir DIR, $d) {
		printf STDERR "Error: Cannot read %s directory : %s", $d, $!;
		next;
	    }
	    
	    foreach my $tt2 (sort grep(/\.tt2$/,readdir DIR)) {
		push @templates, "$d/$tt2";
	    }
	    
	    closedir DIR;
	}

	foreach my $tpl (@templates) {
	    unless (rename $tpl, "$tpl.oldtemplate") {
		printf STDERR
		    "Error : failed to rename %s to %s.oldtemplate : %s\n",
		    $tpl, $tpl, $!;
		next;
	    }

	    &Log::do_log('notice','File %s renamed %s', $tpl, "$tpl.oldtemplate");
	}
    }


    ## Clean buggy list config files
    if (&tools::lower_version($previous_version, '5.1b')) {
	Log::do_log('notice', 'Cleaning buggy list config files...');
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    $list->save_config($list->robot->get_address('listmaster'));
	}
    }

    ## Fix a bug in Sympa 5.1
    if (&tools::lower_version($previous_version, '5.1.2')) {
	Log::do_log('notice', 'Rename archives/log. files...');
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    my $l = $list->name; 
	    if (-f $list->dir . '/archives/log.') {
		rename $list->dir . '/archives/log.',
		    $list->dir . '/archives/log.00';
	    }
	}
    }

    if (&tools::lower_version($previous_version, '5.2a.1')) {

	## Fill the robot_subscriber and robot_admin fields in DB
	&Log::do_log('notice','Updating the new robot_subscriber and robot_admin  Db fields...');

	foreach my $r (@{Robot::get_robots()}) {
	    my $all_lists = List::get_lists($r, {'skip_sync_admin' => 1});
	    foreach my $list ( @$all_lists ) {
		foreach my $table ('subscriber','admin') {
		    unless (SDM::do_query(
			q{UPDATE %s_table
			  SET robot_%s = %s
			  WHERE list_%s = %s},
			$table,
			$table,
			SDM::quote($list->domain),
			$table,
			SDM::quote($list->name)
		    )) {
			Log::do_log('err',
			    'Unable to fille the robot_admin and robot_subscriber fields in database for robot %s.',
			    $r);
			Site->send_notify_to_listmaster(
			    'upgrade_failed',
			    {'error' => $SDM::db_source->{'db_handler'}->errstr});
			return undef;
		    }
		}
		
		## Force Sync_admin
		$list = List->new($list->name, $list->robot, {'force_sync_admin' => 1});
	    }
	}

	## Rename web archive directories using 'domain' instead of 'host'
	&Log::do_log('notice','Renaming web archive directories with the list domain...');
	
	my $root_dir = Site->arc_path;
	unless (opendir ARCDIR, $root_dir) {
	    &Log::do_log('err',"Unable to open $root_dir : $!");
	    return undef;
	}
	
	foreach my $dir (sort readdir(ARCDIR)) {
	    next if (($dir =~ /^\./o) || (! -d $root_dir.'/'.$dir)); ## Skip files and entries starting with '.'
		     
	    my ($listname, $listdomain) = split /\@/, $dir;

	    next unless $listname and $listdomain;

	    my $list = new List $listname;
	    unless (defined $list) {
		&Log::do_log('notice',"Skipping unknown list $listname");
		next;
	    }
	    
	    if ($listdomain ne $list->domain) {
		my $old_path = $root_dir.'/'.$listname.'@'.$listdomain;		
		my $new_path = $root_dir.'/'.$listname.'@'.$list->domain;

		if (-d $new_path) {
		    &Log::do_log('err',"Could not rename %s to %s ; directory already exists", $old_path, $new_path);
		    next;
		}else {
		    unless (rename $old_path, $new_path) {
			&Log::do_log('err',"Failed to rename %s to %s : %s", $old_path, $new_path, $!);
			next;
		    }
		    &Log::do_log('notice', "Renamed %s to %s", $old_path, $new_path);
		}
	    }		     
	}
	close ARCDIR;
	
    }

    ## DB fields of enum type have been changed to int
    if (&tools::lower_version($previous_version, '5.2a.1')) {
	
	if (&SDM::use_db && Site->db_type eq 'mysql') {
	    my %check = ('subscribed_subscriber' => 'subscriber_table',
			 'included_subscriber' => 'subscriber_table',
			 'subscribed_admin' => 'admin_table',
			 'included_admin' => 'admin_table');

	    foreach my $field (keys %check) {
		my $statement;
		my $sth;

		$sth = SDM::do_query(q{SELECT max(%s) FROM %s},
		    $field, $check{$field});
		unless ($sth) {
		    Log::do_log('err', 'Unable to execute SQL statement');
		    return undef;
		}

		my $max = $sth->fetchrow();
		$sth->finish();		

		## '0' has been mapped to 1 and '1' to 2
		## Restore correct field value
		if ($max > 1) {
		    ## 1 to 0
		    Log::do_log('notice',
			'Fixing DB field %s ; turning 1 to 0...', $field);
		    my $rows;
		    $sth = SDM::do_query(
			q{UPDATE %s SET %s = %d WHERE %s = %d},
			$check{$field}, $field, 0, $field, 1
		    );
		    unless ($sth) {
			Log::do_log('err',
			    'Unable to execute SQL statement');
			return undef;
		    }
		    $rows = $sth->rows;
		    Log::do_log('notice', 'Updated %d rows', $rows);

		    ## 2 to 1
		    Log::do_log('notice',
			'Fixing DB field %s ; turning 2 to 1...', $field);
		    
		    $statement = sprintf "UPDATE %s SET %s=%d WHERE (%s=%d)", $check{$field}, $field, 1, $field, 2;

		    $sth = SDM::do_query(
			q{UPDATE %s SET %s = %d WHERE %s = %d},
			$check{$field}, $field, 1, $field, 2
		    );
		    unless ($sth) {
			Log::do_log('err',
			    'Unable to execute SQL statement');
			return undef;
		    }
		    $rows = $sth->rows;
		    Log::do_log('notice', 'Updated %d rows', $rows);
		}

		## Set 'subscribed' data field to '1' is none of 'subscribed'
		## and 'included' is set		
		Log::do_log('notice',
		    'Updating subscribed field of the subscriber table...');
		my $rows;
		$sth = SDM::do_query(
		    q{UPDATE subscriber_table
		      SET subscribed_subscriber = 1
		      WHERE (included_subscriber IS NULL OR
			     included_subscriber <> 1) AND
			    (subscribed_subscriber IS NULL OR
			     subscribed_subscriber <> 1)});
		unless ($sth) {
		    Log::fatal_err("Unable to execute SQL statement");
		}
		$rows = $sth->rows;
		Log::do_log('notice','%d rows have been updated', $rows);
	    }
	}
    }

    ## Rename bounce sub-directories
    if (&tools::lower_version($previous_version, '5.2a.1')) {

	&Log::do_log('notice','Renaming bounce sub-directories adding list domain...');
	
	my $root_dir = Site->bounce_path;
	unless (opendir BOUNCEDIR, $root_dir) {
	    &Log::do_log('err',"Unable to open $root_dir : $!");
	    return undef;
	}
	
	foreach my $dir (sort readdir(BOUNCEDIR)) {
	    ## Skip files and entries starting with '.'
	    next if (($dir =~ /^\./o) || (! -d $root_dir.'/'.$dir));
	    ## Directory already include the list domain
	    next if ($dir =~ /\@/);

	    my $listname = $dir;
	    my $list = new List $listname;
	    unless (defined $list) {
		Log::do_log('notice', 'Skipping unknown list %s', $listname);
		next;
	    }
	    
	    my $old_path = $root_dir . '/' . $listname;		
	    my $new_path = $root_dir . '/' . $list->get_id;
	    
	    if (-d $new_path) {
		&Log::do_log('err',"Could not rename %s to %s ; directory already exists", $old_path, $new_path);
		next;
	    }else {
		unless (rename $old_path, $new_path) {
		    &Log::do_log('err',"Failed to rename %s to %s : %s", $old_path, $new_path, $!);
		    next;
		}
		&Log::do_log('notice', "Renamed %s to %s", $old_path, $new_path);
	    }
	}
	close BOUNCEDIR;
    }

    ## Update lists config using 'include_list'
    if (&tools::lower_version($previous_version, '5.2a.1')) {
	
	&Log::do_log('notice','Update lists config using include_list parameter...');

	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    if (@{$list->include_list}) {
		my $include_lists = $list->include_list;
		my $changed = 0;
		foreach my $index (0..$#{$include_lists}) {
		    my $incl = $include_lists->[$index];
		    my $incl_list = new List ($incl);
		    
		    if (defined $incl_list and
			$incl_list->domain ne $list->domain) {
			Log::do_log('notice',
			    'Update config file of list %s, including list %s',
			    $list, $incl_list);
			$include_lists->[$index] = $incl_list->get_id();
			$changed = 1;
		    }
		}
		if ($changed) {
		    $list->include_list($include_lists);
		    $list->save_config($list->robot->get_address('listmaster'));
		}
	    }
	}	
    }

    ## New mhonarc ressource file with utf-8 recoding
    if (&tools::lower_version($previous_version, '5.3a.6')) {
	
	&Log::do_log('notice','Looking for customized mhonarc-ressources.tt2 files...');
	foreach my $vr (@{Robot::get_robots()}) {
	    my $etc_dir = $vr->etc;

	    if (-f $etc_dir.'/mhonarc-ressources.tt2') {
		my $new_filename = $etc_dir.'/mhonarc-ressources.tt2'.'.'.time;
		rename $etc_dir.'/mhonarc-ressources.tt2', $new_filename;
		&Log::do_log('notice', "Custom %s file has been backed up as %s", $etc_dir.'/mhonarc-ressources.tt2', $new_filename);
		Site->send_notify_to_listmaster(
		    'file_removed',
						 [$etc_dir.'/mhonarc-ressources.tt2', $new_filename]);
	    }
	}


	&Log::do_log('notice', 'Rebuilding web archives...');
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    next unless %{$list->web_archive}; #FIXME: always true
	    my $file = Site->queueoutgoing . '/.rebuild.' . $list->get_id();
	    
	    unless (open REBUILD, ">$file") {
		&Log::do_log('err','Cannot create %s', $file);
		next;
	    }
	    print REBUILD ' ';
	    close REBUILD;
	}	

    }

    ## Changed shared documents name encoding
    ## They are Q-encoded therefore easier to store on any filesystem with any encoding
    if (&tools::lower_version($previous_version, '5.3a.8')) {
	&Log::do_log('notice','Q-Encoding web documents filenames...');

	Language::PushLang(Site->lang);
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    if (-d $list->dir . '/shared') {
		&Log::do_log('notice','  Processing list %s...', $list);

		## Determine default lang for this list
		## It should tell us what character encoding was used for filenames
		&Language::SetLang($list->lang);
		my $list_encoding = &Language::GetCharset();

		my $count = tools::qencode_hierarchy($list->dir . '/shared', $list_encoding);

		if ($count) {
		    Log::do_log('notice',
			'List %s : %d filenames has been changed',
			$list, $count);
		}
	    }
	}
	Language::PopLang();
    }

    ## We now support UTF-8 only for custom templates, config files, headers and footers, info files
    ## + web_tt2, scenari, create_list_templatee, families
    if (&tools::lower_version($previous_version, '5.3b.3')) {
	&Log::do_log('notice','Encoding all custom files to UTF-8...');

	my (@directories, @files);

	## Site level
	foreach my $type ('mail_tt2','web_tt2','scenari','create_list_templates','families') {
	    if (-d Site->etc.'/'.$type) {
		push @directories, [Site->etc.'/'.$type, Site->lang];
	    }
	}

	foreach my $f (
	    Conf::get_sympa_conf(),
	    Conf::get_wwsympa_conf(),
	    Site->etc . '/topics.conf',
	    Site->etc . '/auth.conf'
    ) {
	    if (-f $f) {
		push @files, [$f, Site->lang];
	    }
	}

	## Go through Virtual Robots
	foreach my $vr (@{Robot::get_robots()}) {
	    foreach my $type ('mail_tt2','web_tt2','scenari','create_list_templates','families') {
		if (-d $vr->etc . '/' . $type) {
		    push @directories, [$vr->etc . '/' . $type, $vr->lang];
		}
	    }

	    foreach my $f ('robot.conf','topics.conf','auth.conf') {
		if (-f $vr->etc . '/' . $f) {
		    push @files, [$vr->etc . '/' . $f, $vr->lang];
		}
	    }
	}

	## Search in Lists
	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    foreach my $f ('config','info','homepage','message.header','message.footer') {
		if (-f $list->dir . '/' . $f){
		    push @files, [$list->dir . '/' . $f, $list->lang];
		}
	    }

	    foreach my $type ('mail_tt2','web_tt2','scenari') {
		my $directory = $list->dir . '/' . $type;
		if (-d $directory) {
		    push @directories, [$directory, $list->lang];
		}	    
	    }
	}

	## Search language directories
	foreach my $pair (@directories) {
	    my ($d, $lang) = @$pair;
	    unless (opendir DIR, $d) {
		next;
	    }

	    if ($d =~ /(mail_tt2|web_tt2)$/) {
		foreach my $subdir (grep(/^[a-z]{2}(_[A-Z]{2})?$/, readdir DIR)) {
		    if (-d "$d/$subdir") {
			push @directories, ["$d/$subdir", $subdir];
		    }
		}
		closedir DIR;

	    }elsif ($d =~ /(create_list_templates|families)$/) {
		foreach my $subdir (grep(/^\w+$/, readdir DIR)) {
		    if (-d "$d/$subdir") {
			push @directories, ["$d/$subdir", Site->lang];
		    }
		}
		closedir DIR;
	    }
	}

	foreach my $pair (@directories) {
	    my ($d, $lang) = @$pair;
	    unless (opendir DIR, $d) {
		next;
	    }
	    foreach my $file (readdir DIR) {
		next unless (($d =~ /mail_tt2|web_tt2|create_list_templates|families/ && $file =~ /\.tt2$/) ||
			     ($d =~ /scenari$/ && $file =~ /\w+\.\w+$/));
		push @files, [$d.'/'.$file, $lang];
	    }
	    closedir DIR;
	}

	## Do the encoding modifications
	## Previous versions of files are backed up with the date extension
	my $total = &to_utf8(\@files);
	&Log::do_log('notice','%d files have been modified', $total);
    }

    ## giving up subscribers flat files ; moving subscribers to the DB
    ## Also giving up old 'database' mode
    if (&tools::lower_version($previous_version, '5.4a.1')) {
	
	&Log::do_log('notice','Looking for lists with user_data_source parameter set to file or database...');

	my $all_lists = List::get_lists('Site');
	foreach my $list ( @$all_lists ) {
	    if ($list->user_data_source eq 'file') {
		&Log::do_log('notice',
		    'List %s ; changing user_data_source from file to include2...',
		    $list);

		my @users = List::_load_list_members_file($list->dir . '/subscribers');
		
		$list->user_data_source = 'include2';
		$list->total(0);
		
		## Add users to the DB
		$list->add_list_member(@users);
		my $total = $list->{'add_outcome'}{'added_members'};
		if (defined $list->{'add_outcome'}{'errors'}) {
		    &Log::do_log('err', 'Failed to add users: %s',$list->{'add_outcome'}{'errors'}{'error_message'});
		}
		
		&Log::do_log('notice','%d subscribers have been loaded into the database', $total);
		
		unless ($list->save_config('automatic')) {
		    Log::do_log('err',
			'Failed to save config file for list %s', $list);
		}
	    }elsif ($list->user_data_source eq 'database') {

		Log::do_log('notice',
		    'List %s ; changing user_data_source from database to include2...',
		    $list);

		unless ($list->update_list_member('*', {'subscribed' => 1})) {
		    &Log::do_log('err', 'Failed to update subscribed DB field');
		}

		$list->user_data_source = 'include2';

		unless ($list->save_config('automatic')) {
		    Log::do_log('err',
			'Failed to save config file for list %s', $list);
		}
	    }
	}
    }

    if (&tools::lower_version($previous_version, '5.5a.1')) {

      ## Remove OTHER/ subdirectories in bounces
      &Log::do_log('notice', "Removing obsolete OTHER/ bounce directories");
      if (opendir BOUNCEDIR, Site->bounce_path) {
	
	foreach my $subdir (sort grep (!/^\.+$/,readdir(BOUNCEDIR))) {
	  my $other_dir = Site->bounce_path . '/'.$subdir.'/OTHER';
	  if (-d $other_dir) {
	    &tools::remove_dir($other_dir);
	    &Log::do_log('notice', "Directory $other_dir removed");
	  }
	}
	
	close BOUNCEDIR;
 
      }else {
	&Log::do_log('err', "Failed to open directory Site->queuebounce : $!");	
      }

   }

   if (&tools::lower_version($previous_version, '6.1b.5')) {
		## Encoding of shared documents was not consistent with recent versions of MIME::Encode
		## MIME::EncWords::encode_mimewords() used to encode characters -!*+/ 
		## Now these characters are preserved, according to RFC 2047 section 5 
		## We change encoding of shared documents according to new algorithm
		&Log::do_log('notice','Fixing Q-encoding of web document filenames...');
		my $all_lists = List::get_lists('Site');
		foreach my $list ( @$all_lists ) {
			if (-d $list->dir . '/shared') {
				&Log::do_log('notice','  Processing list %s...', $list);

				my @all_files;
				&tools::list_dir($list->dir, \@all_files, 'utf-8');
				
				my $count;
				foreach my $f_struct (reverse @all_files) {
					my $new_filename = $f_struct->{'filename'};
					
					## Decode and re-encode filename
					$new_filename = &tools::qencode_filename(&tools::qdecode_filename($new_filename));
					
					if ($new_filename ne $f_struct->{'filename'}) {
						## Rename file
						my $orig_f = $f_struct->{'directory'}.'/'.$f_struct->{'filename'};
						my $new_f = $f_struct->{'directory'}.'/'.$new_filename;
						&Log::do_log('notice', "Renaming %s to %s", $orig_f, $new_f);
						unless (rename $orig_f, $new_f) {
							&Log::do_log('err', "Failed to rename %s to %s : %s", $orig_f, $new_f, $!);
							next;
						}
						$count++;
					}
				}
				if ($count) {
					Log::do_log('notice',
					    'List %s : %d filenames has been changed',
					    $list->name, $count);
				}
			}
		}
		
   }		
    if (&tools::lower_version($previous_version, '6.3a')) {
	# move spools from file to database.
	my %spools_def = ('queue' =>  'msg',
			  'queuebounce' => 'bounce',
			  'queuedistribute' => 'msg',
			  'queuedigest' => 'digest',
			  'queuemod' => 'mod',
			  'queuesubscribe' =>  'subscribe',
			  'queuetopic' => 'topic',
			  'queueautomatic' => 'automatic',
			  'queueauth' => 'auth',
			  'queueoutgoing' => 'archive',
			  'queuetask' => 'task');
   if (&tools::lower_version($previous_version, '6.1.11')) {
	## Exclusion table was not robot-enabled.
	Log::do_log('notice','fixing robot column of exclusion table.');
	my $sth = SDM::do_query(q{SELECT * FROM exclusion_table});
	unless ($sth) {
	    Log::do_log('err',
		'Unable to gather informations from the exclusions table.');
	}
	my @robots = @{Robot::get_robots() || []};
	while (my $data = $sth->fetchrow_hashref){
	    next
		if defined $data->{'robot_exclusion'} and
		$data->{'robot_exclusion'} ne '';
	    ## Guessing right robot for each exclusion.
	    my $valid_robot = '';
	    my @valid_robot_candidates;
	    foreach my $robot (@robots) {
		if (my $list = new List($data->{'list_exclusion'},$robot)) {
		    if ($list->is_list_member($data->{'user_exclusion'})) {
			push @valid_robot_candidates,$robot;
		    }
		}
	    }
	    if ($#valid_robot_candidates == 0) {
		$valid_robot = $valid_robot_candidates[0];
		my $sth = SDM::do_query(
		    q{UPDATE exclusion_table
		      SET robot_exclusion = %s
		      WHERE list_exclusion = %s AND user_exclusion = %s},
		    SDM::quote($valid_robot->domain),
		    SDM::quote($data->{'list_exclusion'}),
		    SDM::quote($data->{'user_exclusion'})
		);
		unless ($sth) {
		    &Log::do_log('err','Unable to update entry (%s,%s) in exclusions table (trying to add robot %s)',$data->{'list_exclusion'},$data->{'user_exclusion'},$valid_robot);
		}
	    }else {
		Log::do_log('err',
		    "Exclusion robot could not be guessed for user '%s' in list '%s'. Either this user is no longer subscribed to the list or the list appears in more than one robot (or the query to the database failed). Here is the list of robots in which this list name appears: '%s'",
		    $data->{'user_exclusion'},
		    $data->{'list_exclusion'},
		    join(', ', map { $_->domain } @valid_robot_candidates)
		);
	    }
	}
	## Caching all list config
	&Log::do_log('notice', 'Caching all list config to database...');
	List::get_lists('Site', { 'reload_config' => 1 });
	&Log::do_log('notice', '...done');
	}

	foreach my $spoolparameter (keys %spools_def ){
	    # task is to be done later
	    next if ($spoolparameter eq 'queuetask');

	    my $spooldir = Site->$spoolparameter;

	    unless (-d $spooldir){
		&Log::do_log('info',"Could not perform migration of spool %s because it is not a directory", $spoolparameter);
		next;
   }
	    &Log::do_log('notice',"Performing upgrade for spool  %s ",$spooldir);

	    my $spool = new Sympaspool($spools_def{$spoolparameter});
	    if (!opendir(DIR, $spooldir)) {
		&Log::fatal_err("Can't open dir %s: %m", $spooldir); ## No return.
	    }
	    my @qfile = sort tools::by_date grep (!/^\./,readdir(DIR));
	    closedir(DIR);
	    my $filename;
	    my $listname;
	    my $robot_id;

	    my $ignored = '';
	    my $performed = '';
	    
	    ## Scans files in queue
	    foreach my $filename (sort @qfile) {
		my $type;
		my $list;
		my ($listname, $robot_id, $robot);	
		my %meta ;

		&Log::do_log('notice'," spool : $spooldir, file $filename");
		if (-d $spooldir.'/'.$filename){
		    &Log::do_log('notice',"%s/%s est un répertoire",$spooldir,$filename);
		    next;
		}				

		if (($spoolparameter eq 'queuedigest')){
		    unless ($filename =~ /^([^@]*)\@([^@]*)$/){$ignored .= ','.$filename; next;}
		    $listname = $1;
		    $robot_id = $2;
		    $meta{'date'} = (stat($spooldir.'/'.$filename))[9];
		}elsif (($spoolparameter eq 'queueauth')||($spoolparameter eq 'queuemod')){
		    unless ($filename =~ /^([^@]*)\@([^@]*)\_(.*)$/){$ignored .= ','.$filename;next;}
		    $listname = $1;
		    $robot_id = $2;
		    $meta{'authkey'} = $3;
		    $meta{'date'} = (stat($spooldir.'/'.$filename))[9];
		}elsif ($spoolparameter eq 'queuetopic'){
		    unless ($filename =~ /^([^@]*)\@([^@]*)\_(.*)$/){$ignored .= ','.$filename;next;}
		    $listname = $1;
		    $robot_id = $2;
		    $meta{'authkey'} = $3;
		    $meta{'date'} = (stat($spooldir.'/'.$filename))[9];
		}elsif ($spoolparameter eq 'queueoutgoing'){
		    unless ($filename =~ /^(\S+)\.(\d+)\.\d+\.\d+$/) {
			$ignored .= ',' . $filename;
			next;
		    }
		    my $recipient = $1;
		    ($listname, $robot_id) = split /\@/, $recipient;
		    $meta{'date'} = $2;
		    $robot_id = lc($robot_id || Site->domain);
		    ## check if robot exists
		    unless ($robot = Robot->new($robot_id)) {
			$ignored .= ',' . $filename;
			next;
		    }
		}elsif ($spoolparameter eq 'queuesubscribe'){
		    my $match = 0;		    
		    foreach my $robot (@{Robot::get_robots()}) {
			my $robot_id = $robot->domain;
			Log::do_log('notice', 'robot : %s', $robot_id);
			if ($filename =~ /^([^@]*)\@$robot_id\.(.*)$/){
			    $listname = $1;
			    $meta{'authkey'} = $2;
			    $meta{'date'} = (stat($spooldir.'/'.$filename))[9];
			    $match = 1;
			}
		    }
		    unless ($match){$ignored .= ','.$filename;next;}
		}elsif (($spoolparameter eq 'queue')||($spoolparameter eq 'queuebounce')){
		    ## Don't process temporary files created by queue bouncequeue queueautomatic (T.xxx)
		    next if ($filename =~ /^T\./);

		    unless ($filename =~ /^(\S+)\.(\d+)\.\w+$/) {
			$ignored .= ',' . $filename;
			next;
		    }
		    my $recipient = $1;
		    ($listname, $robot_id) = split /\@/, $recipient;
		    $meta{'date'} = $2;
		    $robot_id = lc($robot_id || Site->domain);
		    ## check if robot exists
		    unless ($robot = Robot->new($robot_id)) {
			$ignored .= ',' . $filename;
			next;
		    }

		    if ($spoolparameter eq 'queue') {
			my ($name, $type) = $robot->split_listname($listname);
			if ($name) {
			    $listname = $name;
			    $meta{'type'} = $type if $type;

			    my $email = $robot->email;
			    my $host = Site->host;

			    my $priority;

			    if ($listname eq $robot->listmaster_email) {
				$priority = 0;
			    }elsif ($type eq 'request') {
				$priority = $robot->request_priority;
			    }elsif ($type eq 'owner') {
				$priority = $robot->owner_priority;
			    } elsif ($listname =~
				/^(sympa|$email)(\@$host)?$/i) {	
				$priority = $robot->sympa_priority;
				$listname ='';
			    }
			    $meta{'priority'} = $priority;
			}
		    }
		}

		$listname = lc($listname);
		$robot_id = lc($robot_id || Site->domain);
		## check if robot exists
		unless ($robot = Robot->new($robot_id)) {
		    $ignored .= ',' . $filename;
		    next;
		}

		$meta{'robot'} = $robot_id if $robot_id;
		$meta{'list'} = $listname if $listname;
		$meta{'priority'} = 1 unless $meta{'priority'};
		
		unless (open FILE, $spooldir.'/'.$filename) {
		    &Log::do_log('err', 'Cannot open message file %s : %s',  $filename, $!);
		    return undef;
		}
		my $messageasstring;
		while (<FILE>){
		    $messageasstring = $messageasstring.$_;
		}
		close(FILE);

		if ($spoolparameter eq 'queuesubscribe') {
		    my @lines = split '\n', $messageasstring;
		    $meta{'sender'} = shift @lines;
		    $messageasstring = join '\n', @lines;
		    my @subparts = split '\|\|',$messageasstring;
		    if ($#subparts > 0) {
			$messageasstring = join '||',@subparts;
		    }else {
			$messageasstring = $subparts[0];
			if ($messageasstring =~ /<custom_attributes>/) {
			    $messageasstring = '||'.$messageasstring;
			}else {
			    $messageasstring = $messageasstring.'||';
			}
		    }
		    $messageasstring .= "\n";
		}
		
		my $messagekey = $spool->store($messageasstring,\%meta);
		unless($messagekey) {
		    &Log::do_log('err',"Could not load message %s/%s in db spool",$spooldir, $filename);
		    next;
		}

		if ($spoolparameter eq 'queuemod') {
		    my $html_view_dir = $spooldir.'/.'.$filename;
		    my $list_html_view_dir = Site->viewmail_dir.'/mod/'.$listname.'@'.$robot_id;
		    my $new_html_view_dir = $list_html_view_dir.'/'.$meta{'authkey'};
		    unless (tools::mkdir_all($list_html_view_dir, 0755)) {
			&Log::do_log('err', 'Could not create list html view directory %s: %s', $list_html_view_dir, $!);
			exit 1;
		    }
		    unless (File::Copy::Recursive::dircopy($html_view_dir, $new_html_view_dir)) {
			&Log::do_log('err', 'Could not rename %s to %s: %s', $html_view_dir,$new_html_view_dir, $!);
			exit 1;
		    }
		}
		mkdir $spooldir.'/copy_by_upgrade_process/'  unless (-d $spooldir.'/copy_by_upgrade_process/');		
		
		my $source = $spooldir.'/'.$filename;
		my $goal = $spooldir.'/copy_by_upgrade_process/'.$filename;

		&Log::do_log('notice','source %s, goal %s',$source,$goal);
		# unless (&File::Copy::copy($spooldir.'/'.$filename, $spooldir.'/copy_by_upgrade_process/'.$filename)) {
		unless (&File::Copy::copy($source, $goal)) {
		    &Log::do_log('err', 'Could not rename %s to %s: %s', $source,$goal, $!);
		    exit 1;
		}
		
		unless (unlink ($spooldir.'/'.$filename)) {
		    &Log::do_log('err',"Could not unlink message %s/%s . Exiting",$spooldir, $filename);
		}
		$performed .= ','.$filename;
	    } 	    
	    &Log::do_log('info',"Upgrade process for spool %s : ignored files %s",$spooldir,$ignored);
	    &Log::do_log('info',"Upgrade process for spool %s : performed files %s",$spooldir,$performed);
	}	
    }

    ## We have obsoleted wwsympa.conf.  It would be migrated to sympa.conf.
    if (&tools::lower_version($previous_version, '6.2a.33')) {
	my $sympa_conf = Conf::get_sympa_conf();
	my $wwsympa_conf = Conf::get_wwsympa_conf();
	my $fh;
	my %migrated = ();
	my @newconf = ();
	my $date;

	## Some sympa.conf parameters were overridden by wwsympa.conf.
	## Others prefer sympa.conf.
	my %wwsconf_override = (
	    'arc_path'                   => 'yes',
	    'archive_default_index'      => 'yes',
	    'bounce_path'                => 'yes',
	    'cookie_domain'              => 'NO',
	    'cookie_expire'              => 'yes',
	    'custom_archiver'            => 'yes',
	    'default_home'               => 'NO',
	    'export_topics'              => 'yes',
	    'html_editor_file'           => 'NO', # 6.2a
	    'html_editor_init'           => 'NO',
	    'ldap_force_canonical_email' => 'NO',
	    'log_facility'               => 'yes',
	    'mhonarc'                    => 'yes',
	    'password_case'              => 'NO',
	    'review_page_size'           => 'yes',
	    'title'                      => 'NO',
	    'use_fast_cgi'               => 'yes',
	    'use_html_editor'            => 'NO',
	    'viewlogs_page_size'         => 'yes',
	    'wws_path'                   => undef,
	);
	## Old params
	my %old_param = (
	    'alias_manager' => 'No more used, using ' . Site->alias_manager,
	    'wws_path'      => 'No more used',
	    'icons_url' =>
		'No more used. Using static_content/icons instead.',
	    'robots' =>
		'Not used anymore. Robots are fully described in their respective robot.conf file.',
	    'htmlarea_url'  => 'No longer supported',
	    'archived_pidfile'           => 'No more used',
	    'bounced_pidfile'            => 'No more used',
	    'task_manager_pidfile'       => 'No more used',
	);

	## Set language of new file content
	Language::PushLang(Site->lang);
	$date = Language::gettext_strftime("%d.%b.%Y-%H.%M.%S",
	    localtime time);

	if (-r $wwsympa_conf) {
	    ## load only sympa.conf
	    my $conf = Conf::load_robot_conf(
		{'robot' => '*', 'no_db' => 1, 'return_result' => 1}
	    );

	    my %infile = ();
	    ## load defaults
	    foreach my $p (@confdef::params) {
		next unless $p->{'name'};
		next unless $p->{'file'};
		next unless $p->{'file'} eq 'wwsympa.conf';
		$infile{$p->{'name'}} = $p->{'default'};
	    }
	    ## get content of wwsympa.conf
	    open my $fh, '<', $wwsympa_conf;
	    while (<$fh>) {
		next if /^\s*#/;
		chomp $_;
		next unless /^\s*(\S+)\s+(.+)$/i;
		my ($k, $v) = ($1, $2);
		$infile{$k} = $v;
	    }
	    close $fh;

	    my $name;
	    foreach my $p (@confdef::params) {
		next unless $p->{'name'};
		$name = $p->{'name'};
		next unless exists $infile{$name};

		unless ($p->{'file'} and $p->{'file'} eq 'wwsympa.conf') {
		    ## may it exist in wwsympa.conf?
		    $migrated{'unknown'} ||= {};
		    $migrated{'unknown'}->{$name} = [$p, $infile{$name}];
		} elsif (exists $conf->{$name}) {
		    if ($wwsconf_override{$name} eq 'yes') {
			## does it override sympa.conf?
			$migrated{'override'} ||= {};
			$migrated{'override'}->{$name} = [$p, $infile{$name}];
		    } elsif (defined $conf->{$name}) {
			## or, is it there in sympa.conf?
			$migrated{'duplicate'} ||= {};
			$migrated{'duplicate'}->{$name} = [$p, $infile{$name}];
		    } else {
			## otherwise, use values in wwsympa.conf
			$migrated{'add'} ||= {};
			$migrated{'add'}->{$name} = [$p, $infile{$name}];
		    }
		} else {
		    ## otherwise, use values in wwsympa.conf
		    $migrated{'add'} ||= {};
		    $migrated{'add'}->{$name} = [$p, $infile{$name}];
		}
		delete $infile{$name};
	    }
	    ## obsoleted or unknown parameters
	    foreach my $name (keys %infile) {
		if ($old_param{$name}) {
		    $migrated{'obsolete'} ||= {};
		    $migrated{'obsolete'}->{$name} =
			[{'name' => $name, 'gettext_id' => $old_param{$name}},
			 $infile{$name}];
		} else {
		    $migrated{'unknown'} ||= {};
		    $migrated{'unknown'}->{$name} =
			[{'name' => $name,
			  'gettext_id' => "Unknown parameter"},
			 $infile{$name}];
		}
	    }
	}

	## Add contents to sympa.conf
	if (%migrated) {
	    open $fh, '<', $sympa_conf or die $!;
	    @newconf = <$fh>;
	    close $fh;
	    $newconf[$#newconf] .= "\n" unless $newconf[$#newconf] =~ /\n\z/;

	    push @newconf, "\n" . ('#' x 76) . "\n" . '#### ' .
		Language::gettext("Migration from wwsympa.conf") .  "\n" .
		'#### ' . $date . "\n" .  ('#' x 76) . "\n\n";

	    foreach my $type (qw(duplicate add obsolete unknown)) {
		my %newconf = %{$migrated{$type} || {}};
		next unless scalar keys %newconf;

		push @newconf, tools::wrap_text(
		    Language::gettext("Migrated Parameters\nFollowing parameters were migrated from wwsympa.conf."), '#### ', '#### ') . "\n"
		    if $type eq 'add';
		push @newconf, tools::wrap_text(
		    Language::gettext("Overriding Parameters\nFollowing parameters existed both in sympa.conf and wwsympa.conf.  Previous release of Sympa used those in wwsympa.conf.  Comment-out ones you wish to be disabled."), '#### ', '#### ') . "\n"
		    if $type eq 'override';
		push @newconf, tools::wrap_text(
		    Language::gettext("Duplicate of sympa.conf\nThese parameters were found in both sympa.conf and wwsympa.conf.  Previous release of Sympa used those in sympa.conf.  Uncomment ones you wish to be enabled."), '#### ', '#### ') . "\n"
		    if $type eq 'duplicate';
		push @newconf, tools::wrap_text(
		    Language::gettext("Old Parameters\nThese parameters are no longer used."),
		    '#### ', '#### ') . "\n"
		    if $type eq 'obsolete';
		push @newconf, tools::wrap_text(
		    Language::gettext("Unknown Parameters\nThough these parameters were found in wwsympa.conf, they were ignored.  You may simply remove them."),
		    '#### ', '#### ') . "\n"
		    if $type eq 'unknown';

		foreach my $k (sort keys %newconf) {
		    my ($param, $v) = @{$newconf{$k}};

		    push @newconf, tools::wrap_text(
			Language::gettext($param->{'gettext_id'}), '## ', '## ')
			if defined $param->{'gettext_id'};
		    push @newconf, tools::wrap_text(
			Language::gettext($param->{'gettext_comment'}), '## ', '## ')
			if defined $param->{'gettext_comment'};
		    if (defined $v and
			($type eq 'add' or $type eq 'override')) {
			push @newconf,
			    sprintf("%s\t%s\n\n", $param->{'name'}, $v);
		    } else {
			push @newconf,
			    sprintf("#%s\t%s\n\n", $param->{'name'}, $v);
		    }
		}
	    }
	}

	## Restore language
	Language::PopLang();

	if (%migrated) {
	    warn sprintf("Unable to rename %s : %s", $sympa_conf, $!)
		unless rename $sympa_conf, "$sympa_conf.$date";
	    ## Write new config files
	    my $umask = umask 037;
	    unless (open $fh, '>', $sympa_conf) {
		umask $umask;
		die sprintf("Unable to open %s : %s", $sympa_conf, $!);
	    }
	    umask $umask;
	    chown [getpwnam(Sympa::Constants::USER)]->[2],
		[getgrnam(Sympa::Constants::GROUP)]->[2], $sympa_conf;
	    print $fh @newconf;
	    close $fh;

	    ## Keep old config file
	    printf "%s has been updated.\nPrevious version has been saved as %s.\n",
		$sympa_conf, "$sympa_conf.$date";
	}

	if (-r $wwsympa_conf) {
	    ## Keep old config file
	    warn sprintf("Unable to rename %s : %s", $wwsympa_conf, $!)
		unless rename $wwsympa_conf, "$wwsympa_conf.$date";
	    printf "%s will NO LONGER be used.\nPrevious version has been saved as %s.\n",
		$wwsympa_conf, "$wwsympa_conf.$date";
	}
    }

    return 1;
}

##DEPRECATED: Use SDM::probe_db().
##sub probe_db {
##    &SDM::probe_db();
##}

##DEPRECATED: Use SDM::data_structure_uptodate().
##sub data_structure_uptodate {
##    &SDM::data_structure_uptodate();
##}

## used to encode files to UTF-8
## also add X-Attach header field if template requires it
## IN : - arrayref with list of filepath/lang pairs
sub to_utf8 {
    my $files = shift;

    my $with_attachments = qr{ archive.tt2 | digest.tt2 | get_archive.tt2 | listmaster_notification.tt2 | 
				   message_report.tt2 | moderate.tt2 |  modindex.tt2 | send_auth.tt2 }x;
    my $total;
    
    foreach my $pair (@{$files}) {
	my ($file, $lang) = @$pair;
	unless (open(TEMPLATE, $file)) {
	    &Log::do_log('err', "Cannot open template %s", $file);
	    next;
	}
	
	my $text = '';
	my $modified = 0;

	## If filesystem_encoding is set, files are supposed to be encoded according to it
	my $charset;
	if ((defined $Conf::Conf::Ignored_Conf{'filesystem_encoding'})&($Conf::Conf::Ignored_Conf{'filesystem_encoding'} ne 'utf-8')) {
	    $charset = $Conf::Conf::Ignored_Conf{'filesystem_encoding'};
	}else {	    
	    &Language::PushLang($lang);
	    $charset = &Language::GetCharset;
	    &Language::PopLang;
	}
	
	# Add X-Sympa-Attach: headers if required.
	if (($file =~ /mail_tt2/) && ($file =~ /\/($with_attachments)$/)) {
	    while (<TEMPLATE>) {
		$text .= $_;
		if (m/^Content-Type:\s*message\/rfc822/i) {
		    while (<TEMPLATE>) {
			if (m{^X-Sympa-Attach:}i) {
			    $text .= $_;
			    last;
			}
			if (m/^[\r\n]+$/) {
			    $text .= "X-Sympa-Attach: yes\n";
			    $modified = 1;
			    $text .= $_;
			    last;
			}
			$text .= $_;
		    }
		}
	    }
	} else {
	    $text = join('', <TEMPLATE>);
	}
	close TEMPLATE;
	
	# Check if template is encoded by UTF-8.
	if ($text =~ /[^\x20-\x7E]/) {
	    my $t = $text;
	    eval {
		&Encode::decode('UTF-8', $t, Encode::FB_CROAK);
	      };
	    if ($@) {
		eval {
		    $t = $text;
		    &Encode::from_to($t, $charset, "UTF-8", Encode::FB_CROAK);
		};
		if ($@) {
		    &Log::do_log('err',"Template %s cannot be converted from %s to UTF-8", $charset, $file);
		} else {
		    $text = $t;
		    $modified = 1;
		}
	    }
	}
	
	next unless $modified;
	
	my $date = strftime("%Y.%m.%d-%H.%M.%S", localtime(time));
	unless (rename $file, $file.'@'.$date) {
	    &Log::do_log('err', "Cannot rename old template %s", $file);
	    next;
	}
	unless (open(TEMPLATE, ">$file")) {
	    &Log::do_log('err', "Cannot open new template %s", $file);
	    next;
	}
	print TEMPLATE $text;
	close TEMPLATE;
	unless (&tools::set_file_rights(file => $file,
					user =>  Sympa::Constants::USER,
					group => Sympa::Constants::GROUP,
					mode =>  0644,
					))
	{
	    &Log::do_log('err','Unable to set rights on %s',Site->db_name);
	    next;
	}
	&Log::do_log('notice','Modified file %s ; original file kept as %s', $file, $file.'@'.$date);
	
	$total++;
    }

    return $total;
}


# md5_encode_password : Version later than 5.4 uses MD5 fingerprint instead of symetric crypto to store password.
#  This require to rewrite paassword in database. This upgrade IS NOT REVERSIBLE
sub md5_encode_password {

    my $total = 0;

    &Log::do_log('notice', 'Upgrade::md5_encode_password() recoding password using MD5 fingerprint');
    
    unless (SDM::check_db_connect('just_try')) {
	return undef;
    }

    my $sth = SDM::do_query(
	q{SELECT email_user, password_user FROM user_table}
    );
    unless ($sth) {
	Log::do_log('err', 'Unable to execute SQL statement');
	return undef;
    }

    $total = 0;
    my $total_md5 = 0 ;

    while (my $user = $sth->fetchrow_hashref('NAME_lc')) {
	my $clear_password ;
	if ($user->{'password_user'} =~ /^[0-9a-f]{32}/){
	    Log::do_log('info',
		'password from %s already encoded as MD5 fingerprint',
		$user->{'email_user'});
	    $total_md5++ ;
	    next;
	}	
	
	## Ignore empty passwords
	next if ($user->{'password_user'} =~ /^$/);

	if ($user->{'password_user'} =~ /^crypt.(.*)$/) {
	    $clear_password = &tools::decrypt_password($user->{'password_user'});
	}else{ ## Old style cleartext passwords
	    $clear_password = $user->{'password_user'};
	}

	$total++;

	## Updating Db
	unless (SDM::do_query(
	    q{UPDATE user_table
	      SET password_user = %s
	      WHERE email_user = %s},
	    SDM::quote(Auth::password_fingerprint($clear_password)),
	    SDM::quote($user->{'email_user'})
	)) {
	    Log::do_log('err', 'Unable to execute SQL statement');
	    return undef;
	}
    }
    $sth->finish();

    &Log::do_log('info',"Updating password storage in table user_table using MD5 for %d users",$total) ;
    if ($total_md5) {
	&Log::do_log('info',"Found in table user %d password stored using MD5, did you run Sympa before upgrading ?", $total_md5 );
    }    
    return $total;
}

 
## Packages must return true.
1;
