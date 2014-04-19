# File: ChanOps.pm
# Author: pragma_
#
# Purpose: Provides channel operator status tracking and commands.

package PBot::ChanOps;

use warnings;
use strict;

use vars qw($VERSION);
$VERSION = $PBot::PBot::VERSION;

use Time::HiRes qw(gettimeofday);

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to ChanOps should be key/value pairs, not hash reference");
  }

  my ($class, %conf) = @_;

  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;

  my $pbot = delete $conf{pbot};
  if(not defined $pbot) {
    Carp::croak("Missing pbot reference to ChanOps");
  }

  $self->{pbot} = $pbot;
  $self->{unban_timeout} = PBot::DualIndexHashObject->new(pbot => $pbot, name => 'Unban Timeouts', filename => "$pbot->{data_dir}/unban_timeouts");
  $self->{op_commands} = {};
  $self->{is_opped} = {};

  $pbot->timer->register(sub { $self->check_opped_timeouts   }, 10);
  $pbot->timer->register(sub { $self->check_unban_timeouts   }, 10);
}

sub gain_ops {
  my $self = shift;
  my $channel = shift;
  
  if(not exists $self->{is_opped}->{$channel}) {
    $self->{pbot}->conn->privmsg("chanserv", "op $channel");
    $self->{is_opped}->{$channel}{timeout} = gettimeofday + 300; # assume we're going to be opped
  } else {
    $self->perform_op_commands($channel);
  }
}

sub lose_ops {
  my $self = shift;
  my $channel = shift;
  $self->{pbot}->conn->privmsg("chanserv", "op $channel -" . $self->{pbot}->botnick);
}

sub add_op_command {
  my ($self, $channel, $command) = @_;
  push @{ $self->{op_commands}->{$channel} }, $command;
}

sub perform_op_commands {
  my $self = shift;
  my $channel = shift;

  $self->{pbot}->logger->log("Performing op commands...\n");
  while(my $command = shift @{ $self->{op_commands}->{$channel} }) {
    if($command =~ /^mode (.*?) (.*)/i) {
      $self->{pbot}->conn->mode($1, $2);
      $self->{pbot}->logger->log("  executing mode $1 $2\n");
    } elsif($command =~ /^kick (.*?) (.*?) (.*)/i) {
      $self->{pbot}->conn->kick($1, $2, $3) unless $1 =~ /\Q$self->{pbot}->botnick\E/i;
      $self->{pbot}->logger->log("  executing kick on $1 $2 $3\n");
    }
  }
  $self->{pbot}->logger->log("Done.\n");
}

sub ban_user {
  my $self = shift;
  my ($mask, $channel) = @_;

  $self->add_op_command($channel, "mode $channel +b $mask");
  $self->gain_ops($channel);
}

sub unban_user {
  my $self = shift;
  my ($mask, $channel) = @_;
  $self->{pbot}->logger->log("Unbanning $channel $mask\n");
  if($self->{unban_timeout}->find_index($channel, $mask)) {
    $self->{unban_timeout}->hash->{$channel}->{$mask}{timeout} = gettimeofday + 7200; # try again in 2 hours if unban doesn't immediately succeed
    $self->{unban_timeout}->save;
  }
  $self->add_op_command($channel, "mode $channel -b $mask");
  $self->gain_ops($channel);
}

sub ban_user_timed {
  my $self = shift;
  my ($mask, $channel, $length) = @_;

  $self->ban_user($mask, $channel);
  $self->{unban_timeout}->hash->{$channel}->{$mask}{timeout} = gettimeofday + $length;
  $self->{unban_timeout}->save;
}

sub check_unban_timeouts {
  my $self = shift;

  return if not $self->{pbot}->{joined_channels};

  my $now = gettimeofday();

  foreach my $channel (keys %{ $self->{unban_timeout}->hash }) {
    foreach my $mask (keys %{ $self->{unban_timeout}->hash->{$channel} }) {
      if($self->{unban_timeout}->hash->{$channel}->{$mask}{timeout} < $now) {
        $self->unban_user($mask, $channel);
      }
    }
  }
}

sub check_opped_timeouts {
  my $self = shift;
  my $now = gettimeofday();

  foreach my $channel (keys %{ $self->{is_opped} }) {
    if($self->{is_opped}->{$channel}{timeout} < $now) {
      $self->lose_ops($channel);
      delete $self->{is_opped}->{$channel}; # assume chanserv is alive and deop will succeed
    } else {
      # my $timediff = $self->{is_opped}->{$channel}{timeout} - $now;
      # $self->{pbot}->logger->log("deop $channel in $timediff seconds\n");
    }
  }
}

1;
