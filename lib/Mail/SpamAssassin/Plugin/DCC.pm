=head1 NAME

Mail::SpamAssassin::Plugin::DCC - perform DCC check of messages

The DCC or Distributed Checksum Clearinghouse is a system of servers
collecting and counting checksums of millions of mail messages. The
counts can be used by SpamAssassin to detect and reject or filter spam.

Because simplistic checksums of spam can be easily defeated, the main
DCC checksums are fuzzy and ignore aspects of messages.  The fuzzy
checksums are changed as spam evolves.

See http://www.rhyolite.com/anti-spam/dcc/ for more information about
DCC.

=head1 SYNOPSIS

  loadplugin     Mail::SpamAssassin::Plugin::DCC

=over 4

=cut

# <@LICENSE>
# Copyright 2004 Apache Software Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# </@LICENSE>

package Mail::SpamAssassin::Plugin::DCC;

# Make the main dbg() accessible in our package w/o an extra function
*dbg=\&Mail::SpamAssassin::Plugin::dbg;

use Mail::SpamAssassin::Plugin;
use IO::Socket;
use strict;
use warnings;
use bytes;

use vars qw(@ISA);
@ISA = qw(Mail::SpamAssassin::Plugin);

sub new {
  my $class = shift;
  my $mailsaobject = shift;

  $class = ref($class) || $class;
  my $self = $class->SUPER::new($mailsaobject);
  bless ($self, $class);

  # DCC is not available
  if ($mailsaobject->{local_tests_only}) {
    $self->{dcc_available} = 0;
    dbg("dcc: local tests only, disabling DCC");
  }
  else {
    $self->{dcc_available} = 1;
    dbg("dcc: network tests on, attempting DCC");
  }

  $self->register_eval_rule("check_dcc");

  $self->set_config($mailsaobject->{conf});

  return $self;
}

sub set_config {
  my($self, $conf) = @_;
  my @cmds = ();

=head1 USER OPTIONS

=item use_dcc (0|1)		(default: 1)

Whether to use DCC, if it is available.  DCC is used to check message
signatures over the network against the Distributed Checksum Clearinghouse.

=cut

  push(@cmds, {
    setting => 'use_dcc',
    default => 1,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_BOOL,
  });

=item dcc_timeout n		(default: 10)

How many seconds you wait for DCC to complete, before scanning continues
without the DCC results.

=cut

  push (@cmds, {
    setting => 'dcc_timeout',
    default => 10,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC,
  });

=item dcc_body_max NUMBER

=item dcc_fuz1_max NUMBER

=item dcc_fuz2_max NUMBER

This option sets how often a message's body/fuz1/fuz2 checksum must have been
reported to the DCC server before SpamAssassin will consider the DCC check as
matched.

As nearly all DCC clients are auto-reporting these checksums you should set
this to a relatively high value, e.g. C<999999> (this is DCC's MANY count).

The default is C<999999> for all these options.

=cut

  push (@cmds, {
    setting => 'dcc_body_max',
    default => 999999,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
  },
  {
    setting => 'dcc_fuz1_max',
    default => 999999,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
  },
  {
    setting => 'dcc_fuz2_max',
    default => 999999,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC
  });

=head1 ADMINISTRATOR OPTIONS

=item dcc_home STRING

This option tells SpamAssassin specifically where to find the dcc homedir.
If C<dcc_path> is not specified, it will default to looking in
C<dcc_home/bin> for dcc client instead of relying on SpamAssassin to find it
in the current PATH.  If it isn't found there, it will look in the current
PATH. If a C<dccifd> socket is found in C<dcc_home>, it will use that
interface that instead of C<dccproc>.

=cut

  push (@cmds, {
    setting => 'dcc_home',
    is_admin => 1,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
  });

=item dcc_dccifd_path STRING

This option tells SpamAssassin specifically where to find the dccifd socket.
If C<dcc_dccifd_path> is not specified, it will default to looking in
C<dcc_home> If a C<dccifd> socket is found, it will use it instead of
C<dccproc>.

=cut

  push (@cmds, {
    setting => 'dcc_dccifd_path',
    is_admin => 1,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
  });

=item dcc_path STRING

This option tells SpamAssassin specifically where to find the C<dccproc>
client instead of relying on SpamAssassin to find it in the current PATH.
Note that if I<taint mode> is enabled in the Perl interpreter, you should
use this, as the current PATH will have been cleared.

=cut

  push (@cmds, {
    setting => 'dcc_path',
    is_admin => 1,
    default => undef,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING
  });

=item dcc_options options

Specify additional options to the dccproc(8) command. Please note that only
[A-Z -] is allowed for security reasons.

The default is C<-R>.

=cut

  push (@cmds, {
    setting => 'dcc_options',
    is_admin => 1,
    default => '-R',
    code => sub {
      my ($self, $key, $value, $line) = @_;
      if ($value !~ /^([A-Z -]+)/) {
	return $Mail::SpamAssassin::Conf::INVALID_VALUE;
      }
      $self->{dcc_options} = $1;
    }
  });

  $conf->{parser}->register_commands(\@cmds);
}

sub is_dccifd_available {
  my ($self) = @_;

  my $dcchome = $self->{main}->{conf}->{dcc_home} || '';
  my $dccifd = $self->{main}->{conf}->{dcc_dccifd_path} || '';

  if (!$dccifd && ($dcchome && -S "$dcchome/dccifd")) {
    $dccifd = "$dcchome/dccifd";
  }

  unless ($dccifd && -S $dccifd && -w _ && -r _) {
    dbg("dcc: dccifd is not available: no r/w dccifd socket found");
    return 0;
  }

  # remember any found dccifd socket
  $self->{main}->{conf}->{dcc_dccifd_path} = $dccifd;

  dbg("dcc: dccifd is available: " . $self->{main}->{conf}->{dcc_dccifd_path});
  return 1;
}

sub is_dccproc_available {
  my ($self) = @_;

  my $dcchome = $self->{main}->{conf}->{dcc_home} || '';
  my $dccproc = $self->{main}->{conf}->{dcc_path} || '';

  if (!$dccproc && ($dcchome && -x "$dcchome/bin/dccproc")) {
    $dccproc  = "$dcchome/bin/dccproc";
  }
  unless ($dccproc) {
    $dccproc = Mail::SpamAssassin::Util::find_executable_in_env_path('dccproc');
  }

  unless ($dccproc && -x $dccproc) {
    dbg("dcc: dccproc is not available: no executable dccproc found");
    return 0;
  }

  # remember any found dccproc
  $self->{main}->{conf}->{dcc_path} = $dccproc;

  dbg("dcc: dccifd is available: " . $self->{main}->{conf}->{dcc_path});
  return 1;
}

sub get_dcc_interface {
  my ($self) = @_;

  if (!$self->{main}->{conf}->{use_dcc}) {
    dbg("dcc: use_dcc option not enabled, disabling DCC");
    $self->{dcc_interface} = "disabled";
    $self->{dcc_available} = 0;
  }
  elsif ($self->is_dccifd_available()) {
    $self->{dcc_interface} = "dccifd";
  }
  elsif ($self->is_dccproc_available()) {
    $self->{dcc_interface} = "dccproc";
  }
  else {
    dbg("dcc: no dccifd or dccproc found, disabling DCC");
    $self->{dcc_interface} = "none";
    $self->{dcc_available} = 0;
  }
}

sub check_dcc {
  my ($self, $permsgstatus, $full) = @_;

  $self->get_dcc_interface() unless $self->{dcc_interface};
  return 0 unless $self->{dcc_available};

  # First check if there's already a X-DCC header with value of "bulk"
  # and short-circuit if there is -- someone upstream might already have
  # checked DCC for us.
  return 1 if (grep(/^X-DCC-(?:[^:]{1,80}-)?Metrics:.*bulk/m, $permsgstatus->get('ALL')));

  if ($$full eq '') {
    dbg("dcc: empty message, skipping dcc check");
    return 0;
  }

  if ($self->{dcc_interface} eq "dccifd") {
    return $self->dccifd_lookup($permsgstatus, $full);
  }
  else {
    return $self->dccproc_lookup($permsgstatus, $full);
  }
  return 0;
}

sub dccifd_lookup {
  my ($self, $permsgstatus, $fulltext) = @_;
  my $response = "";
  my %count;
  my $left;
  my $right;
  my $timeout = $self->{main}->{conf}->{dcc_timeout};
  my $sockpath = $self->{main}->{conf}->{dcc_dccifd_path};

  $count{body} = 0;
  $count{fuz1} = 0;
  $count{fuz2} = 0;

  $permsgstatus->enter_helper_run_mode();

  my $oldalarm = 0;

  eval {
    # safe to use $SIG{ALRM} here instead of Util::trap_sigalrm_fully(),
    # since there are no killer regexp hang dangers here
    local $SIG{ALRM} = sub { die "__alarm__\n" };

    $oldalarm = alarm $timeout;

    my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM,
      Peer => $sockpath) || dbg("dcc: failed to open socket") && die;

    # send the options and other parameters to the daemon
    $sock->print("header\n") || dbg("dcc: failed write") && die; # options
    $sock->print("0.0.0.0\n") || dbg("dcc: failed write") && die; # client
    $sock->print("\n") || dbg("dcc: failed write") && die; # HELO value
    $sock->print("\n") || dbg("dcc: failed write") && die; # sender
    $sock->print("unknown\r\n") || dbg("dcc: failed write") && die; # recipients
    $sock->print("\n") || dbg("dcc: failed write") && die; # recipients

    $sock->print($$fulltext);

    $sock->shutdown(1) || dbg("dcc: failed socket shutdown: $!") && die;

    $sock->getline() || dbg("dcc: failed read status") && die;
    $sock->getline() || dbg("dcc: failed read multistatus") && die;

    my @null = $sock->getlines();
    if (!@null) {
      dbg("dcc: failed read header");
      die;
    }

    # the first line will be the header we want to look at
    chomp($response = shift @null);
    # but newer versions of DCC fold the header if it's too long...
    while (my $v = shift @null) {
      last unless ($v =~ s/^\s+/ /);  # if this line wasn't folded, stop
      chomp $v;
      $response .= $v;
    }

    dbg("dcc: dccifd got response: $response");

    alarm $oldalarm;
  };

  # do NOT reinstate $oldalarm here; we may already have done that in
  # the success case.  leave it to the error handler below
  my $err = $@;
  $permsgstatus->leave_helper_run_mode();

  if ($err) {
    alarm $oldalarm;
    $response = undef;
    if ($err =~ /__alarm__/) {
      dbg("dcc: dccifd check timed out after $timeout secs.");
      return 0;
    } else {
      warn("dcc: dccifd -> check skipped: $! $err");
      return 0;
    }
  }

  if (!defined $response || $response !~ /^X-DCC/) {
    dbg("dcc: dccifd check failed - no X-DCC returned: $response");
    return 0;
  }

  if ($response =~ /^X-DCC-(.*)-Metrics: (.*)$/) {
    $permsgstatus->{tag_data}->{DCCB} = $1;
    $permsgstatus->{tag_data}->{DCCR} = $2;
  }

  $response =~ s/many/999999/ig;
  $response =~ s/ok\d?/0/ig;

  if ($response =~ /Body=(\d+)/) {
    $count{body} = $1+0;
  }
  if ($response =~ /Fuz1=(\d+)/) {
    $count{fuz1} = $1+0;
  }
  if ($response =~ /Fuz2=(\d+)/) {
    $count{fuz2} = $1+0;
  }

  if ($count{body} >= $self->{main}->{conf}->{dcc_body_max} ||
      $count{fuz1} >= $self->{main}->{conf}->{dcc_fuz1_max} ||
      $count{fuz2} >= $self->{main}->{conf}->{dcc_fuz2_max})
  {
    dbg(sprintf("dcc: listed: BODY=%s/%s FUZ1=%s/%s FUZ2=%s/%s",
		$count{body}, $self->{main}->{conf}->{dcc_body_max},
		$count{fuz1}, $self->{main}->{conf}->{dcc_fuz1_max},
		$count{fuz2}, $self->{main}->{conf}->{dcc_fuz2_max}));
    return 1;
  }
  
  return 0;
}

sub dccproc_lookup {
  my ($self, $permsgstatus, $fulltext) = @_;
  my $response = undef;
  my %count;
  my $timeout = $self->{main}->{conf}->{dcc_timeout};

  $count{body} = 0;
  $count{fuz1} = 0;
  $count{fuz2} = 0;

  $permsgstatus->enter_helper_run_mode();

  # use a temp file here -- open2() is unreliable, buffering-wise, under spamd
  my $tmpf = $permsgstatus->create_fulltext_tmpfile($fulltext);
  my $oldalarm = 0;

  eval {
    # safe to use $SIG{ALRM} here instead of Util::trap_sigalrm_fully(),
    # since there are no killer regexp hang dangers here
    local $SIG{ALRM} = sub { die "__alarm__\n" };
    local $SIG{PIPE} = sub { die "__brokenpipe__\n" };

    $oldalarm = alarm $timeout;

    # Note: not really tainted, these both come from system conf file.
    my $path = Mail::SpamAssassin::Util::untaint_file_path($self->{main}->{conf}->{dcc_path});

    my $opts = '';
    if ($self->{main}->{conf}->{dcc_options} =~ /^([^\;\'\"\0]+)$/) {
      $opts = $1;
    }

    dbg("dcc: opening pipe: " . join(' ', $path, "-H", $opts, "< $tmpf"));

    my $pid = Mail::SpamAssassin::Util::helper_app_pipe_open(*DCC,
	$tmpf, 1, $path, "-H", split(' ', $opts));
    $pid or die "$!\n";

    my @null = <DCC>;
    close DCC;
    if (!@null) {
      dbg("dcc: failed read header");
      die;
    }

    # the first line will be the header we want to look at
    chomp($response = shift @null);
    # but newer versions of DCC fold the header if it's too long...
    while (my $v = shift @null) {
      last unless ($v =~ s/^\s+/ /);  # if this line wasn't folded, stop
      chomp $v;
      $response .= $v;
    }

    unless (defined($response)) {
      die("dcc: no response\n");	# yes, this is possible
    }

    dbg("dcc: got response: $response");

    # note: this must be called BEFORE leave_helper_run_mode()
    # $self->cleanup_kids($pid);
    alarm $oldalarm;
  };

  # do NOT reinstate $oldalarm here; we may already have done that in
  # the success case.  leave it to the error handler below
  my $err = $@;
  $permsgstatus->leave_helper_run_mode();

  if ($err) {
    alarm $oldalarm;
    if ($err =~ /^__alarm__$/) {
      dbg("dcc: check timed out after $timeout secs.");
    } elsif ($err =~ /^__brokenpipe__$/) {
      dbg("dcc: check failed: broken pipe");
    } elsif ($err eq "no response\n") {
      dbg("dcc: check failed: no response");
    } else {
      warn("dcc: check failed: $err\n");
    }
    return 0;
  }

  if (!defined($response) || $response !~ /^X-DCC/) {
    dbg("dcc: check failed: no X-DCC returned (did you create a map file?): $response");
    return 0;
  }

  if ($response =~ /^X-DCC-(.*)-Metrics: (.*)$/) {
    $permsgstatus->{tag_data}->{DCCB} = $1;
    $permsgstatus->{tag_data}->{DCCR} = $2;
  }

  $response =~ s/many/999999/ig;
  $response =~ s/ok\d?/0/ig;

  if ($response =~ /Body=(\d+)/) {
    $count{body} = $1+0;
  }
  if ($response =~ /Fuz1=(\d+)/) {
    $count{fuz1} = $1+0;
  }
  if ($response =~ /Fuz2=(\d+)/) {
    $count{fuz2} = $1+0;
  }

  if ($count{body} >= $self->{main}->{conf}->{dcc_body_max} ||
      $count{fuz1} >= $self->{main}->{conf}->{dcc_fuz1_max} ||
      $count{fuz2} >= $self->{main}->{conf}->{dcc_fuz2_max})
  {
    dbg(sprintf("dcc: listed: BODY=%s/%s FUZ1=%s/%s FUZ2=%s/%s",
		$count{body}, $self->{main}->{conf}->{dcc_body_max},
		$count{fuz1}, $self->{main}->{conf}->{dcc_fuz1_max},
		$count{fuz2}, $self->{main}->{conf}->{dcc_fuz2_max}));
    return 1;
  }

  return 0;
}
