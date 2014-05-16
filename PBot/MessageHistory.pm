# File: MessageHistory.pm
# Author: pragma_
#
# Purpose: Keeps track of who has said what and when, as well as their
# nickserv accounts and alter-hostmasks.  
#
# Used in conjunction with AntiFlood and Quotegrabs for kick/ban on
# flood/ban-evasion and grabbing quotes, respectively.

package PBot::MessageHistory;

use warnings;
use strict;

use Getopt::Long qw(GetOptionsFromString);
use Time::HiRes qw(gettimeofday tv_interval);
use Time::Duration;
use Carp ();

use PBot::MessageHistory_SQLite;

sub new {
  if(ref($_[1]) eq 'HASH') {
    Carp::croak("Options to " . __FILE__ . " should be key/value pairs, not hash reference");
  }

  my ($class, %conf) = @_;
  my $self = bless {}, $class;
  $self->initialize(%conf);
  return $self;
}

sub initialize {
  my ($self, %conf) = @_;
  $self->{pbot} = delete $conf{pbot} // Carp::croak("Missing pbot reference to " . __FILE__);
  $self->{filename} = delete $conf{filename} // $self->{pbot}->{data_dir} . '/message_history.sqlite3';

  $self->{database} = PBot::MessageHistory_SQLite->new(pbot => $self->{pbot}, filename => $self->{filename});
  $self->{database}->begin();
  $self->{database}->devalidate_all_channels();

  $self->{MSG_CHAT}       = 0;  # PRIVMSG, ACTION
  $self->{MSG_JOIN}       = 1;  # JOIN
  $self->{MSG_DEPARTURE}  = 2;  # PART, QUIT, KICK
  $self->{MSG_NICKCHANGE} = 3;  # CHANGED NICK

  $self->{pbot}->commands->register(sub { $self->recall_message(@_) },  "recall",  0);

  $self->{pbot}->{atexit}->register(sub { $self->{database}->end(); return; });
}

sub get_message_account {
  my ($self, $nick, $user, $host) = @_;
  return $self->{database}->get_message_account($nick, $user, $host);
}

sub add_message {
  my ($self, $account, $mask, $channel, $text, $mode) = @_;
  $self->{database}->add_message($account, $mask, $channel, { timestamp => scalar gettimeofday, msg => $text, mode => $mode });
}

sub recall_message {
  my ($self, $from, $nick, $user, $host, $arguments) = @_;

  if(not defined $from) {
    $self->{pbot}->logger->log("Command missing ~from parameter!\n");
    return "";
  }

  my $usage = 'Usage: recall [nick [history [channel]]] [-c,channel <channel>] [-t,text,h,history <history>] [+ ...]';

  if(not defined $arguments or not length $arguments) {
    return $usage; 
  }

  $arguments = lc $arguments;

  my @recalls = split /\s\+\s/, $arguments;

  my $getopt_error;
  local $SIG{__WARN__} = sub {
    $getopt_error = shift;
    chomp $getopt_error;
  };

  my $recall_text;

  foreach my $recall (@recalls) {
    my ($recall_nick, $recall_history, $recall_channel);

    my ($ret, $args) = GetOptionsFromString($recall,
      'channel|c=s' => \$recall_channel,
      'text|t|history|h=s' => \$recall_history);

    return "$getopt_error -- $usage" if defined $getopt_error;

    my $channel_arg = 1 if defined $recall_channel;
    my $history_arg = 1 if defined $recall_history;

    $recall_nick = shift @$args;
    $recall_history = shift @$args if not defined $recall_history;
    $recall_channel = shift @$args if not defined $recall_channel;

    # swap nick and channel if recall nick looks like channel and channel wasn't specified
    if(not $channel_arg and $recall_nick =~ m/^#/) {
      my $temp = $recall_nick;
      $recall_nick = $recall_channel;
      $recall_channel = $temp;
    }

    # swap history and channel if history looks like a channel and neither history or channel were specified
    if(not $channel_arg and not $history_arg and $recall_history =~ m/^#/) {
      my $temp = $recall_history;
      $recall_history = $recall_channel;
      $recall_channel = $temp;
    }

    # skip recall command if recalling self without arguments
    $recall_history = $nick eq $recall_nick ? 2 : 1 if defined $recall_nick and not defined $recall_history;

    # set history to most recent message if not specified
    $recall_history = '1' if not defined $recall_history;

    # set channel to current channel if not specified
    $recall_channel = $from if not defined $recall_channel;

    my ($account, $found_nick);

    if(defined $recall_nick) {
      ($account, $found_nick) = $self->{database}->find_message_account_by_nick($recall_nick);

      if(not defined $account) {
        return "I don't know anybody named $recall_nick.";
      }
    }

    my $message;

    if($recall_history =~ /^\d+$/) {
      # integral history
      if(defined $account) {
        my $max_messages = $self->{database}->get_max_messages($account, $recall_channel);
        if($recall_history < 1 || $recall_history > $max_messages) {
          return "Please choose a history between 1 and $max_messages";
        }
      }

      $recall_history--;
      $message = $self->{database}->recall_message_by_count($account, $recall_channel, $recall_history, 'recall');

      if(not defined $message) {
        return "No message found at index $recall_history in channel $recall_channel.";
      }
    } else {
      # regex history
      $message = $self->{database}->recall_message_by_text($account, $recall_channel, $recall_history, 'recall');

      if(not defined $message) {
        if(defined $account) {
          return "No such message for nick $found_nick in channel $recall_channel containing text '$recall_history'";
        } else {
          return "No such message in channel $recall_channel containing text '$recall_history'";
        }
      }
    }

    if(defined $message->{id}) {
      my $hostmask = $self->{database}->find_most_recent_hostmask($message->{id}); 
      ($found_nick) = $hostmask =~ m/^([^!]+)/;
      $recall_nick = $found_nick;
    }

    $self->{pbot}->logger->log("$nick ($from) recalled <$recall_nick/$recall_channel> $message->{msg}\n");

    my $text = $message->{msg};
    my $ago = ago(gettimeofday - $message->{timestamp});

    if(not defined $recall_text) {
      if($text =~ s/^\/me\s+//) {
        $recall_text = "[$ago] * $found_nick $text";
      } else {
        $recall_text = "[$ago] <$found_nick> $text";
      }
    } else {
      if($text =~ s/^\/me\s+//) {
        $recall_text .= " [$ago] * $found_nick $text";
      } else {
        $recall_text .= " [$ago] <$found_nick> $text";
      }
    }
  }

  return $recall_text;
}

1;
