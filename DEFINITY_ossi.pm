package DEFINITY_ossi;
# you'd probably prefer to read this documentation with perldoc

=head1 SYNOPSIS

DEFINITY_ossi.pm

=head1 DESCRIPTION

    This module provided access to the ossi interface of an
    Avaya Communication Manager telephone system (aka a Definity PBX).
    Any PBX command available from the SAT terminal can be used.

    The ossi interface is intended as a programmer's interface.
    Interactive users should use the VT220 or 4410 terminal types instead.

    Normally you will want to use the pbx_command method.
    If you want formatted screen capture use the pbx_vt220_command method.

    The xml config file should be located in home directory in the file pbx_connection_auth.xml.
    The format of the config file is:
    <pbx-systems>
        <pbx name='n1'   hostname='localhost' port='22' login='login1'  password='pass1'   connection_type='ssh' atdt='' />
        <pbx name='n2'   hostname='127.0.0.1' port='22' login='login2'  password='pass2'   connection_type='ssh' atdt='' />
    </pbx-systems>

    connection_type can be ssh, ssl or telnet
    if you need to dial a modem or data module then the number to dial goes in the atdt field

=head1 EXAMPLES

 BEGIN { require "./DEFINITY_ossi.pm"; import DEFINITY_ossi; }
 my $DEBUG = 1;
 my $node = new DEFINITY_ossi('n1', $DEBUG);
 unless( $node && $node->status_connection() ) {
 	die("ERROR: Login failed for ". $node->get_node_name() );
 }

 my %fields = ('0003ff00' => '');
 $node->pbx_command("display time", %fields );
 if ( $node->last_command_succeeded() ) {
 	my @ossi_output = $node->get_ossi_objects();
 	my $hash_ref = $ossi_output[0];
 	print "The PBX says the year is ". $hash_ref->{'0003ff00'} ."\n";
 }

 $node->pbx_command("status station 68258");
 if ( $node->last_command_succeeded() ) {
 	my @ossi_output = $node->get_ossi_objects();
 	my $i = 0;
 	foreach my $hash_ref(@ossi_output) {
 		$i++;
 		print "output result $i\n";
 		for my $field ( sort keys %$hash_ref ) {
 			my $value = $hash_ref->{$field};
 			print "\t$field => $value\n";
 		}
 	}
 }

 if ( $node->pbx_vt220_command('status logins') ) {
 	print $node->get_vt220_output();
 }

 $node->do_logoff();

=head1 AUTHOR

Benjamin Roy <benroy@uw.edu>

Copyright: March 2011
License: Apache 2.0

=cut
#back to the code, done with the POD text


use strict;
use Expect;
use Term::VT102;
use Data::Dumper;
use XML::Simple;
local $ENV{XML_SIMPLE_PREFERRED_PARSER} = 'XML::Parser';  # this is the fastest parser

$Expect::Debug         = 0;
$Expect::Exp_Internal  = 0;
$Expect::Log_Stdout    = 0;  #  STDOUT ...

use constant PBX_CONFIG_FILE => 'pbx_connection_auth.xml';
use constant TERMTYPE        => 'ossi4';  # options are ossi, ossi3, or ossi4
use constant TIMEOUT         => 60;

my $DEBUG = 0;

my $telnet_command  = '/usr/bin/telnet';
my $ssh_command     = '/usr/bin/ssh';
my $openssl_command = '/usr/bin/openssl s_client -quiet -connect';


#=============================================================
sub new {
#=============================================================
    my($class, @param) = @_;
    my $self = {};  # Create the anonymous hash reference to hold the object's data.
    bless $self, ref($class) || $class;

    if ($self->_initialize(@param)){
        return($self);
    } else {
        return(0);
    }
}

#=============================================================
sub _initialize {
#=============================================================
    my ($self, $nodename, $debug_param) = @_;

    if ( $debug_param ) {
        $DEBUG = $debug_param;
    }

    print "getting connection parameters for $nodename\n" if $DEBUG;

    my $config = XMLin( "$ENV{HOME}/" . PBX_CONFIG_FILE );
    if ( defined $config->{'pbx'}->{$nodename} ) {
        my $pbx = $config->{'pbx'}->{$nodename};

        ${$self->{'NODENAME'}}        = $nodename;
        ${$self->{'HOSTNAME'}}        = $pbx->{'hostname'};
        ${$self->{'PORT'}}            = $pbx->{'port'};
        ${$self->{'USERNAME'}}        = $pbx->{'login'};
        ${$self->{'PASSWORD'}}        = $pbx->{'password'};
        ${$self->{'CONNECTION_TYPE'}} = $pbx->{'connection_type'};
        ${$self->{'ATDT'}}            = $pbx->{'atdt'};

        print "loaded $nodename config\n" if $DEBUG;
    }
    else {
        my $msg = "ERROR: unknown PBX [$nodename]. Config must be added to config file ". PBX_CONFIG_FILE ." before it can be used in production.";
        print "$msg\n";
        ${$self->{'ERRORMSG'}} = "$msg";
        return(0);
    }

    ${$self->{'CONNECTED'}}	= 0;

    ${$self->{'ERRORMSG'}}	= "";
    ${$self->{'VT220_OUTPUT'}}	= "";
    @{$self->{'VT220_SCREENS'}}	= ();
    ${$self->{'LAST_COMMAND_SUCCEEDED'}}	= 0;

    #  Array to hold generic ossi objects from a "list" command ...
    @{$self->{'OSSI_OBJECTS'}}	= ();

    #  Array to hold stations ...
    @{$self->{'STATIONS'}}	= ();

    #  Hash to hold uniform-dialplan by patterns...
    %{$self->{'UNIFORMDIALPLAN'}} = ();

    # Hash to hold extensions and type
    %{$self->{'EXTENSIONS'}}	= ();

    ${$self->{'SESSION'}} = $self->init_session(
                                        ${$self->{'HOSTNAME'}},
                                        ${$self->{'PORT'}},
                                        ${$self->{'USERNAME'}},
                                        ${$self->{'PASSWORD'}},
                                        ${$self->{'CONNECTION_TYPE'}},
                                        ${$self->{'ATDT'}}
                                    );

    return(1);
}

#=============================================================
sub init_session {
#=============================================================
    my ($self, $host, $port, $username, $password, $connection_type, $atdt) = @_;

    my $success = 0;

    my $s = new Expect;
    $s->raw_pty(1);
    $s->restart_timeout_upon_receive(1);

    my $command;
    if ( $connection_type eq 'telnet' ) {
        $command = "$telnet_command $host $port";
    }
    elsif ( $connection_type eq 'ssh' ) {
        $command = "$ssh_command -o \"StrictHostKeyChecking no\" -p $port -l $username $host";
    }
    elsif ( $connection_type eq 'ssl' ) {
        $command = "$openssl_command $host:$port";  #  Somehow the data module and telnet do not mix
    }
    else {
        my $msg = "ERROR: unhandled connection type requested. [$connection_type]";
        print "$msg\n" if $DEBUG;
        $self->{'ERRORMSG'} .= $msg;
        return(0);
    }

    print "$command\n" if $DEBUG;
    $s->spawn($command);

    if (defined($s)){
        $success = 0;
        $s->expect(TIMEOUT,
            [ 'OK', sub {
                    print "DEBUG Sending: 'ATDT $atdt'\n" if $DEBUG;
                    my $self = shift;
                    print $self "ATDT $atdt\n\r";
                    exp_continue;
            } ],
            [ 'BUSY', sub {
                    my $msg = "ERROR: The phone number was busy.";
                    print "$msg\n" if $DEBUG;
                    $self->{'ERRORMSG'} .= $msg;
            } ],
            [ 'Login resources unavailable', sub {
                    my $msg = "ERROR: No ports available.";
                    print "$msg\n" if $DEBUG;
                    $self->{'ERRORMSG'} .= $msg;
            }],
            [ '-re', '[Ll]ogin:|[Uu]sername:', sub {
                    my $self = shift;
                    print "Login: $username\n" if $DEBUG;
                    print $self "$username\r";
                    exp_continue;
            }],
            [ 'Password:', sub {
                    my $self = shift;
                    print "entering password\n" if $DEBUG;
                    print $self "$password\r";
                    exp_continue;
            }],
            [ 'Terminal Type', sub {
                    my $self = shift;
                    print "entering terminal type ".TERMTYPE."\n" if $DEBUG;
                    print $self TERMTYPE . "\r";
                    exp_continue;
            }],
            [ '-re', '^t$', sub {
                    print "connection established\n" if $DEBUG;
                    $success = 1;
            }],
            [  eof => sub {
                    my $msg = "ERROR: Connection failed with EOF at login.";
                    print "$msg\n" if $DEBUG;
                    $self->{'ERRORMSG'} .= $msg;
            }],
            [  timeout => sub {
                    my $msg = "ERROR: Timeout on login.";
                    print "$msg\n" if $DEBUG;
                    $self->{'ERRORMSG'} .= $msg;
            }]
        );

        if (! $success) {
            return(0);
        }
        else {
            #  Verify command prompt ...
            sleep(1);
            print $s "\rt\r";
            $s->expect(TIMEOUT,
                [ '-re', 'Terminator received but no command active\nt\012'],
                [  eof => sub {
                        $success = 0;
                        my $msg = "ERROR: Connection failed with EOF at verify command prompt.";
                        print "$msg\n" if $DEBUG;
                        $self->{'ERRORMSG'} .= $msg;
                }],
                [  timeout => sub {
                        $success = 0;
                        my $msg = "ERROR: Timeout on verify command prompt.";
                        print "$msg\n" if $DEBUG;
                        $self->{'ERRORMSG'} .= $msg;
                }],
                [ '-re', '^t$', sub {
                        exp_continue;
                }]
            );
            if ($success) {
                    $self->set_connected();
            } else {
                    return(0);
            }
        }
    } else {
        my $msg = "ERROR: Could not create an Expect object.";
        print "$msg\n" if $DEBUG;
        $self->{'ERRORMSG'} .= $msg;
    }
    return($s);
}

#======================================================================
sub do_logoff {
#======================================================================
    my ($self) = @_;
    my $session = ${$self->{'SESSION'}};
    if ( $session ) {
        $session->send("c logoff \rt\r");
        $session->expect(TIMEOUT,
            [ qr/NO CARRIER/i ],
            [ qr/Proceed With Logoff/i, sub { my $self = shift; $self->send("y\r"); } ],
            [ qr/onnection closed/i ] );
        $session->soft_close();
        print "PBX connection disconnected\n" if $DEBUG;
    }
    return(0);
}


#======================================================================
#
# submit a command to the PBX and return the result
# fields can be specified to return only the fields desired
# data values for the fields can be included for "change" commands
#
# a good way to identify field id codes is to use a "display" command and
# compare it to the output of the same command to a VT220 terminal
# for example to see all the fields for a change station you could call this
# function with a "display station" and no field list like this:
#  $node->pbx_command("display station");
#
sub pbx_command {
#======================================================================
    my ($self, $command, %fields) = @_;
    my $ossi_output = {};
    my $this = $self;
    my $session = ${$self->{'SESSION'}};
    my @field_ids;
    my @field_values;
    my $cmd_fields = '';
    my $cmd_values = '';
    my $command_succeeded = 1;
    $self->{'ERRORMSG'} = ''; #reset the error message
    @{$self->{'OSSI_OBJECTS'}} = (); #reset the objects array

    print "DEBUG Processing pbx_command($command, \%fields)\n" if $DEBUG;
    print "DEBUG \%fields contains:\n" if $DEBUG;
    print Dumper(%fields) if $DEBUG;

    for my $field ( sort keys %fields ) {
        my $value = $fields{$field};
        $cmd_fields .= "$field\t";
        $cmd_values .= "$value\t";
    }
    chop $cmd_fields; # remove the trailing \t character
    chop $cmd_values;

    $session->send("c $command\r");
    print "DEBUG Sending \nc $command\n" if $DEBUG;
    if ( $cmd_fields ne '' ) {
        $session->send("f$cmd_fields\r");
        print "f$cmd_fields\n" if $DEBUG;

        $session->send("d$cmd_values\r");
        print "d$cmd_values\n" if $DEBUG;
    }
    $session->send("t\r");
    print "t\n" if $DEBUG;

    $session->expect(TIMEOUT,
    [ '-re', '^f.*\x0a', sub {
        my $self = shift;
        my $a = trim( $self->match() );
        print "DEBUG Matched '$a'\n" if $DEBUG;
        $a =~ s/^f//;  # strip the leading 'f' off
        my ($field_1, $field_2, $field_3, $field_4, $field_5) = split(/\t/, $a, 5);
        #print "field_ids are: $field_1|$field_2|$field_3|$field_4|$field_5\n" if ($DEBUG);
        push(@field_ids, $field_1);
        push(@field_ids, $field_2);
        push(@field_ids, $field_3);
        push(@field_ids, $field_4);
        push(@field_ids, $field_5);
        exp_continue;
    } ],
    [ '-re', '^[dent].*\x0a', sub {
        my $self = shift;
        my $a = trim( $self->match() );
        print "DEBUG Matched '$a'\n" if $DEBUG;

        if ( trim($a) eq "n" || trim($a) eq "t" ) { # end of record output
            # assign values to $ossi_output object
            for (my $i = 0; $i < scalar(@field_ids); $i++) {
                if ( $field_ids[$i] ) {
                    $ossi_output->{$field_ids[$i]} = $field_values[$i];
                }
            }
            #	print Dumper($ossi_output) if $DEBUG;
            delete $ossi_output->{''}; # I'm not sure how this get's added but we don't want it.
            push(@{$this->{'OSSI_OBJECTS'}}, $ossi_output);
            @field_values = ();
            undef $ossi_output;
        }
        elsif ( substr($a,0,1) eq "d" ) { # field data line
            $a =~ s/^d//;  # strip the leading 'd' off
            my ($field_1, $field_2, $field_3, $field_4, $field_5) = split(/\t/, $a, 5);
            #	print "field_values are: $field_1|$field_2|$field_3|$field_4|$field_5\n" if ($DEBUG);
            push(@field_values, $field_1);
            push(@field_values, $field_2);
            push(@field_values, $field_3);
            push(@field_values, $field_4);
            push(@field_values, $field_5);
        }
        elsif ( substr($a,0,1) eq "e" ) { # error message line
            $a =~ s/^e//;  # strip the leading 'd' off
            my ($field_1, $field_2, $field_3, $field_4) = split(/ /, $a, 4);
            my $mess = $field_4;
            print "ERROR: field $field_2 $mess\n" if $DEBUG;
            $this->{'ERRORMSG'} .= "$field_2 $mess\n";
            $command_succeeded = 0;
        }
        else {
            print "ERROR: unknown match \"" . $self->match() ."\"\n";
        }

        unless ( trim($a) eq "t" ) {
            exp_continue;
        }
    } ],
    [  eof => sub {
        $command_succeeded = 0;
        my $msg = "ERROR: Connection failed with EOF in pbx_command($command).";
        print "$msg\n" if $DEBUG;
        $this->{'ERRORMSG'} .= $msg;
    } ],
    [  timeout => sub {
        $command_succeeded = 0;
        my $msg = "ERROR: Timeout in pbx_command($command).";
        print "$msg\n" if $DEBUG;
        $this->{'ERRORMSG'} .= $msg;
    } ],
    );

    if ( $command_succeeded ) {
        $this->{'LAST_COMMAND_SUCCEEDED'} = 1;
        return(1);
    }
    else {
        $this->{'LAST_COMMAND_SUCCEEDED'} = 0;
        return(0);
    }
}


#======================================================================
#
# capture the VT220 terminal screen output of a PBX command
#
sub pbx_vt220_command {
#======================================================================
    my ($self, $command) = @_;
    my $session = ${$self->{'SESSION'}};
    my $command_succeeded = 1;
    $self->{'ERRORMSG'} = ''; #reset the error message
    $self->{'VT220_OUTPUT'} = '';
    @{$self->{'VT220_SCREENS'}} = ();
    my $command_output = '';
    my $ESC         = chr(27);      #  \x1b
    my $CANCEL      = $ESC . "[3~";
    my $NEXT        = $ESC . "[6~";

#4410 keys
#F1=Cancel=<ESC>OP
#F2=Refresh=<ESC>OQ
#F3=Save=<ESC>OR
#F4=Clear=<ESC>OS
#F5=Help=<ESC>OT
#F6=GoTo=<ESC>Or  ...OR... F6=Update=<ESC>OX  ...or.... F6=Edit=<ESC>f6
#F7=NextPg=<ESC>OV
#F8=PrevPg=<ESC>OW

#VT220 keys
#Cancel          ESC[3~      F1
#Refresh         ESC[34~     F2
#Execute         ESC[29~     F3
#Clear Field     ESC[33~     F4
#Help            ESC[28~     F5
#Update Form     ESC[1~      F6
#Next Page       ESC[6~      F7
#Previous Page   ESC[5~      F8

    unless ( $self->status_connection() ) {
        $self->{'ERRORMSG'} .= 'ERROR: No connection to PBX.';
        $self->{'LAST_COMMAND_SUCCEEDED'} = 0;
        return(0);
    }

    # switch the terminal type from ossi to VT220
    $session->send("c newterm\rt\r");
    print "DEBUG switching to VT220 terminal type\n" if $DEBUG;

    $session->expect(TIMEOUT,
        [ 'Terminal Type', sub {
            $session->send("VT220\r");
            print "DEBUG sending VT220\n" if $DEBUG;
            exp_continue;
        }],
        [ '-re', 'Command:', sub {
            print "DEBUG ready for next command.\n" if $DEBUG;
        }],
        [  timeout => sub {
            my $msg = "ERROR: Timeout switching to VT220 terminal type.";
            print "$msg\n" if $DEBUG;
            $self->{'ERRORMSG'} .= $msg;
        }]
    );

    $session->send("$command\r");
    print "DEBUG Sending $command\n" if $DEBUG;

    $session->expect(TIMEOUT,
        [ '-re', '\x1b\[\d;\d\dH\x1b\[0m|\[KCommand:|press CANCEL to quit --  press NEXT PAGE to continue|Command successfully completed', sub {
            # end of screen
            #\[24;1H\x1b\[KCommand:

            my $string = $session->before();
            $string =~ s/\x1b/\n/gm;
            print "DEBUG \$session->before()\n$string\n" if $DEBUG;

            #my $string = $session->before();
            #$string =~ s/\x1b/\n/gm;
            #print "Expect end of page\n$string\n";
            my $a = trim( $session->match() );
            print "DEBUG \$session->match() '$a'\n" if $DEBUG;
            my $current_page = 0;
            my $page_count = 1;
            if ( $session->before() =~ /Page +(\d*) of +(\d*)/ ) {
                $current_page = $1;
                $page_count = $2;
            }
            print "DEBUG on page $current_page out of $page_count pages\n" if $DEBUG;
            my $vt = Term::VT102->new('cols' => 80, 'rows' => 24);
            $vt->process( $session->before() );
            my $row = 0;
            my $screen;
            while ( $row < $vt->rows() ) {
                my $line = $vt->row_plaintext($row);
                $screen .= "$line\n" if $line;
                $row++;
            }
            print $screen if $DEBUG;
            push( @{$self->{'VT220_SCREENS'}}, $screen);
            $command_output .= $screen;
            if ( $session->match() eq 'Command successfully completed') {
                print "DEBUG \$session->match() is 'Command successfully completed'\n" if $DEBUG;
            }
            elsif ( $session->match() eq '[KCommand:') {
                print "DEBUG returned to 'Command:' prompt\n" if $DEBUG;
                if ( $session->after() ne ' ' ) {
                    print "DEBUG \$session->after(): '". $session->after() ."'" if $DEBUG;

                    my $vt = Term::VT102->new('cols' => 80, 'rows' => 24);
                    $vt->process( $session->before() );
                    my $msg = "ERROR: ". $vt->row_plaintext(23);
                    print "$msg\n" if $DEBUG;
                    $self->{'ERRORMSG'} .= $msg;

                    $session->send("$CANCEL");
                    $command_succeeded = 0;
                }
            }
            elsif ($current_page == $page_count) {
                print "DEBUG received last page. command finished\n" if $DEBUG;
                $session->send("$CANCEL");
            }
            elsif ($current_page < $page_count ) {
                print "DEBUG requesting next page\n" if $DEBUG;
                $session->send("$NEXT");
                exp_continue;
            }
            else {
                print "ERROR: unknown condition\n" if $DEBUG;
            }
        }],
        [  eof => sub {
            $command_succeeded = 0;
            my $msg = "ERROR: Connection failed with EOF in pbx_vt220_command($command).";
            print "$msg\n" if $DEBUG;
            $self->{'ERRORMSG'} .= $msg;
        } ],
        [  timeout => sub {
            $command_succeeded = 0;
            my $string = $session->before();
            $string =~ s/\x1b/\n/gm;
            print "ERROR: timeout in pbx_vt220_command($command)\n\$session->before()\n$string\n" if $DEBUG;

            my $vt = Term::VT102->new('cols' => 80, 'rows' => 24);
            $vt->process( $session->before() );
            my $msg = "ERROR: ". $vt->row_plaintext(23);
            print "$msg\n" if $DEBUG;
            $self->{'ERRORMSG'} .= $msg;

            $session->send("$CANCEL");
        } ],
    );

    # switch back to the original ossi terminal type
    print "DEBUG switching back to ossi terminal type\n" if $DEBUG;
    $session->send("$CANCEL");
    $session->send("newterm\r");
    print "DEBUG sending cancel and newterm\n" if $DEBUG;
    $session->expect(TIMEOUT,
        [ 'Terminal Type', sub {
            $session->send(TERMTYPE . "\r");
            print "DEBUG sending ". TERMTYPE ."\n" if $DEBUG;
            exp_continue;
        }],
        [ '-re', '^t$', sub {
            print "DEBUG ready for next command\n" if $DEBUG;
        }],
        [  timeout => sub {
            my $msg = "ERROR: Timeout while switching back to ossi terminal.";
            print "$msg\n" if $DEBUG;
            $self->{'ERRORMSG'} .= $msg;
        }]
    );

    if ( $command_succeeded ) {
        $self->{'LAST_COMMAND_SUCCEEDED'} = 1;
        $self->{'VT220_OUTPUT'} = $command_output;
        print "DEBUG command succeeded\n" if $DEBUG;
        return(1);
    }
    else {
        $self->{'LAST_COMMAND_SUCCEEDED'} = 0;
        print "DEBUG command failed\n" if $DEBUG;
        return(0);
    }

}


#=============================================================
sub trim($) {
#=============================================================
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

#=============================================================
sub get_extension_type {
#=============================================================
    my ($self, $extension) = @_;
    my %hash = %{$self->{'EXTENSIONS'}};
    my $type = $hash{$extension};
    return($type)
}

#=============================================================
sub get_extensions {
#=============================================================
    my ($self) = @_;
    return( sort {$a <=> $b} keys %{$self->{'EXTENSIONS'}} );
}

#=============================================================
sub get_stations {
#=============================================================
    my ($self) = @_;
    while ( my($key,$value) = each(%{$self->{'EXTENSIONS'}}) ) {
            if ($value eq "station-user") {
                    push(@{$self->{'STATIONS'}}, $key);
            }
    }
    return( sort {$a <=> $b} @{$self->{'STATIONS'}} );
}

#=============================================================
sub get_uniform_dialplan {
#=============================================================
    my ($self) = @_;
    return( $self->{'UNIFORMDIALPLAN'} );
}

#=============================================================
sub clear_uniform_dialplan {
#=============================================================
    my ($self) = @_;
    %{$self->{'UNIFORMDIALPLAN'}} = ();
}

#=============================================================
sub clear_stations {
#=============================================================
    my ($self) = @_;
    @{$self->{'STATIONS'}} = ();
}

#=============================================================
sub clear_extensions {
#=============================================================
    my ($self) = @_;
    %{$self->{'EXTENSIONS'}} = ();
}

#=============================================================
sub get_last_error_message {
#=============================================================
    my ($self) = @_;
    return( $self->{'ERRORMSG'} );
}

#=============================================================
sub last_command_succeeded {
#=============================================================
    my ($self) = @_;
    return( $self->{'LAST_COMMAND_SUCCEEDED'} );
}

#=============================================================
sub get_ossi_objects {
#=============================================================
    my ($self) = @_;
    return( @{$self->{'OSSI_OBJECTS'}} );
}

#=============================================================
sub get_vt220_output {
#=============================================================
    my ($self) = @_;
    return($self->{'VT220_OUTPUT'});
}

#=============================================================
sub get_vt220_screens {
#=============================================================
    my ($self) = @_;
    return( @{$self->{'VT220_SCREENS'}} );
}

#=============================================================
sub get_node_name {
#=============================================================
    my ($self) = @_;
    return(${$self->{'NODENAME'}});
}

#=============================================================
sub set_connected {
#=============================================================
    my ($self) = @_;
    ${$self->{'CONNECTED'}} = 1;
}

#=============================================================
sub unset_connected {
#=============================================================
    my ($self) = @_;
    ${$self->{'CONNECTED'}} = 0;
}

#=============================================================
sub status_connection {
#=============================================================
    my ($self) = @_;
    return(${$self->{'CONNECTED'}});
}

1;
