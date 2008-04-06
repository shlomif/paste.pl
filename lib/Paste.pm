#Paste library for paste.debian.net
#Copyright (C) 2007  Alexander Wirt <formorer@debian.org>
#
#This program is free software: you can redistribute it and/or modify
#it under the terms of the GNU Affero General Public License as
#published by the Free Software Foundation, either version 3 of the
#License, or (at your option) any later version.
#
#This program is distributed in the hope that it will be useful,
#but WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#GNU Affero General Public License for more details.
#
#You should have received a copy of the GNU Affero General Public License
#along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Paste;

use strict; 
use warnings; 
use Exporter; 
use Config::IniFiles;
use DBI; 
use Encode; 
use Digest::SHA1  qw(sha1_hex);

use Carp; 

use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);

@EXPORT = qw ( new add_paste delete_paste get_paste get_config_key);
sub new {
	my $invocant = shift;
	my $class = ref($invocant) || $invocant;	
	my $config_file = shift || ''; 
	croak ("Need a configfile") unless -f $config_file; 
	my $config = Config::IniFiles->new( -file => $config_file );	

	unless ($config) {
		my $error = "$!\n"; 
		$error .= join("\n", @Config::IniFiles::errors);
		croak "Could not load configfile '$config_file': $error"; 
	}

	my $dbname = $config->val('database', 'dbname') || carp "Databasename not specified in config";
	my $dbuser = $config->val('database', 'dbuser') || carp "Databaseuser not specified in config";
	my $dbpass = $config->val('database', 'dbpassword') || '';
	my $base_url = $config->val('www', 'base_url') || carp "base_url not specified in config";	

	my $dbh = 
		DBI->connect("dbi:Pg:dbname=$dbname", $dbuser, $dbpass,
			{ RaiseError => 0, PrintError => 0}) or 
			croak "Could not connect to DB: " . $DBI::errstr;

	my $self = {
			config => $config, 
			dbname => $dbname, 
			dbuser => $dbuser, 
			dbpass => $dbpass, 
			dbh => $dbh,
			@_, 
		};

	bless ($self, $class);
	return $self;
}

sub get_config_key () {
	my ($self, $section, $key) = @_; 
	if ($self->{config}->val($section, $key)) {
		return $self->{config}->val($section, $key);
	} else {
		return undef;
	}
}

sub error {
	my $self = shift;
	return $self->{error};
}

=pod

=head2 add_paste( B<code>, B<name>, B<expire>, B<lang> )

=over 4

Adds a new entry to the paste database. 

=over 4 

=item B<code> 

A string with \n or \r\n which represents the paste entry

=item B<name>

The name of the submitter, anonymousif empty

=item B<expire> 

Expire time in seconds from now() 

=item B<lang>

ID of the language for highlight. If 0 highlighting is disabled. 

=back 

=back

=cut

sub add_paste ($$$$) {
	my ($self, $code, $name, $expire, $lang) = @_;
	my $dbh = $self->{dbh}; 
	$name = $name || 'anonymous';

	if ($name !~ /^[^;,'"]{1,30}/i) {
		$self->{error} = "Invalid format for name (no special chars, max 30 chars)";
		return 0;
	}

	if ($expire !~ /^[0-9]+/) {
		$self->{error} = "Expire must be an integer"; 
		return 0;
	}

	if ($expire > 604800) {
		$self->{error} = 'Expiration time can not be longer than 604800 seconds (7 days)'; 
		return 0;
	}

	my $sth = $dbh->prepare("INSERT INTO paste(poster,posted,code,lang_id,expires,sha1) VALUES(?,now(),?,?,?,?)");
	if ($dbh->errstr) {
		$self->{error} = "Could not prepare db statement: " . $dbh->errstr;
		return 0;
	}	
	
	#replace \r\n with \n
	$code =~ s/\r\n/\n/g;
	#use CGI qw(:standard);;
	#print header ( -charset => 'utf-8', -encoding => 'utf-8');
	#even if it already should be valid UTF-8 encoding again won't harm. 
	#Postgresql is a little bit picky about clean UTF-8
	#$code = encode_utf8($code);
	

	#we create some kind of digest here. This will be used for "administrative work". Everyone who has this digest can delete the entry. 
	#in the future the first 8 or so chars will be used as an accesskeys for "hidden" entrys. 
	my $digest = sha1_hex($code . time() . rand());
	
	$sth->execute($name,$code,$lang,$expire,$digest);

	if ($dbh->errstr) {
        $self->{error} = "Could not insert paste into db: " . $dbh->errstr;
        return 0;
    }
	

	#We need to get the id from our database so that the caller is able to
	#generate the proper URLs
	my $id; 
	
	$sth = $dbh->prepare("SELECT id from paste where sha1 = ?");
    if ($dbh->errstr) {
        $self->{error} = "Could not prepare db statement: " . $dbh->errstr;
        return 0;
    }  
	$sth->execute($digest);	
	if ($dbh->errstr) {
        $self->{error} = "Could not retrieve your entry from the paste database: "
			. $dbh->errstr;
        return 0;
    }
	while ( my @row = $sth->fetchrow_array ) {
		$id = $row[0];
	}

	return $id, $digest;
	
}

=pod

=head2 add_comment( B<comment>, B<name>, B<paste_id> )

=over 4

Adds a new comment to the paste database. 

=over 4 

=item B<comment> 

A string with \n or \r\n which represents the comment

=item B<name>

The name of the submitter, anonymous if empty

=item B<paste_id>

The ID of the paste entry where the comment belongs to. 

=back 

=back

=cut

sub add_comment ($$$) {
	my ($self, $comment, $name, $paste_id) = @_;
	my $dbh = $self->{dbh}; 
	$name = $name || 'anonymous';

	if ($name !~ /^[^;,'"]{1,30}/i) {
		$self->{error} = "Invalid format for name (no special chars, max 30 chars)";
		return 0;
	}
	
	#id must be an integer
	if ($paste_id !~ /^[0-9]+$/) {
		$self->{error} = "Invalid id format (must be an integer)";
	}

	my $paste_id_ref = $dbh->selectall_arrayref("SELECT id FROM paste  WHERE id = '$paste_id'"); 
	if ($dbh->errstr) {
		$self->{error} = "Could not prepare db statement: " . $dbh->errstr;
		return 0;
	}
	
	if (! @{$paste_id_ref}) {
		$self->{error} = "No entry with id '$paste_id' found"; 
		return 0;
	}

	my $sth = $dbh->prepare("INSERT INTO comments(name,text,paste_id,date) VALUES(?,?,?,now())");
	if ($dbh->errstr) {
		$self->{error} = "Could not prepare db statement: " . $dbh->errstr;
		return 0;
	}	
	
	#replace \r\n with \n
	$comment =~ s/\r\n/\n/g;

	#even if it already should be valid UTF-8 encoding again won't harm. 
	#Postgresql is a little bit picky about clean UTF-8
	#$comment = encode_utf8($comment);
	
	$sth->execute($name,$comment,$paste_id);

	if ($dbh->errstr) {
        $self->{error} = "Could not insert comment into db: " . $dbh->errstr;
        return 0;
    }
	
	return 1;;
}

=pod

=head2 delete_paste( B<digest> )

=over 4

Deletes a entry from the database. 

=over 4 

=item B<digest> 

The digest of the entry you want to delete

=back 

=back

=cut


sub delete_paste ($) {
	my ($self, $sha1) = @_;
	my $dbh = $self->{dbh}; 

	if ($sha1 !~ /^[0-9a-f]{40}$/i ) {
		$self->{error} = "Digest does not look like a sha1 hex"; 
		return 0;
	}
	my $deleted_id_ref = $dbh->selectall_arrayref("SELECT id from paste where sha1 = '$sha1'"); 

	if (! @{$deleted_id_ref}) {
		$self->{error} = "No entry with digest '$sha1' found"; 
		return 0;
	}
	my $id = @{@{$deleted_id_ref}[0]}[0];
	my $sth = $dbh->prepare("DELETE from paste where sha1 = ?");
	if ($dbh->errstr) {
		$self->{error} = "Could not prepare db statement: " . $dbh->errstr;
		return 0;
	}	
	
	$sth->execute($sha1);

	if ($dbh->errstr) {
        $self->{error} = "Could not delete paste from db: " . $dbh->errstr;
        return 0;
    }
	return $id;
}

=pod

=head2 delete_comment( B<id> )

=over 4

Deletes a comment from the database. 

=over 4 

=item B<id> 

The id of the comment you want to delete

=back 

=back

=cut


sub delete_comment ($) {
	my ($self, $id) = @_;
	my $dbh = $self->{dbh}; 

	if ($id !~ /^[0-9]+$/i ) {
		$self->{error} = "ID does not look like an integer"; 
		return 0;
	}
	my $deleted_comment_ref = $dbh->selectall_arrayref("SELECT id from comments where id = '$id'"); 

	if (! @{$deleted_comment_ref}) {
		$self->{error} = "No entry with id '$id' found"; 
		return 0;
	}
	$id = @{@{$deleted_comment_ref}[0]}[0];
	my $sth = $dbh->prepare("DELETE from comments where id = ?");
	if ($dbh->errstr) {
		$self->{error} = "Could not prepare db statement: " . $dbh->errstr;
		return 0;
	}	
	
	$sth->execute($id);

	if ($dbh->errstr) {
        $self->{error} = "Could not delete comment from db: " . $dbh->errstr;
        return 0;
    }
	return $id;
}

=pod

=head2 get_paste( B<id> )

=over 4

Returns an entry from the database. Returns undef if the entry couldn't be found. Otherwise a hashref with the entry will be returned. Beware that the digest is included. You should not reveal this to externals, otherwise your entrys can be deleted.  

=over 4 

=item B<id> 

The id of the entry you want to retreive

=back 

=back

=cut

sub get_paste ($) {
	my ($self, $id) = @_;
	my $dbh = $self->{dbh};

	my $sth = $dbh->prepare("SELECT * from paste where id = ?"); 
	if ($dbh->errstr) {
		$self->{error} = "Could not prepare db statement: " . $dbh->errstr;
		return 0;
	}

	$sth->execute($id);
	if ($dbh->errstr){ 
		$self->{error} = "Could not get paste from db: " . $dbh->errstr;
		return 0;
	}
	my $hash_ref = $sth->fetchrow_hashref;
	if (defined($hash_ref->{code})) {
		return $hash_ref; 
	} else {
		return undef;
	}
}

sub get_langs () {
	my ($self, $id) = @_;
	my $dbh = $self->{dbh};
	my $ary_ref = $dbh->selectall_arrayref("SELECT * from lang", { Slice => {} }); 
	if ($dbh->errstr) {
		$self->{error} = "Could not get languages vom database: " . $dbh->errstr;
		return 0;
	}
	return $ary_ref;
}

sub get_lang ($) {
	my ($self, $lang) = @_; 
	my $dbh = $self->{dbh};

	my $lang_id_ref = $dbh->selectall_arrayref("SELECT lang_id from lang where \"desc\" = '$lang'");

    if ($dbh->errstr) {
        $self->{error} = "Could not execute db statement: " . $dbh->errstr;
        return 0;
    }
	
    if (! @{$lang_id_ref}) {
        $self->{error} = "Language $lang not found";
        return 0;
    }
    my $id = @{@{$lang_id_ref}[0]}[0];
	return $id;
}
1;

# vim: syntax=perl sw=4 ts=4 noet shiftround

