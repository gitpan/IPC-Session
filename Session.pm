package IPC::Session;

use strict;
use FileHandle;
use IPC::Open3;

use vars qw($VERSION);

$VERSION = '0.03';

=head1 NAME

IPC::Session - remote shell persistent session object; encapsulates open3()

=head1 SYNOPSIS

 use IPC::Session;

 # open ssh session to fred
 # -- set timeout of 30 seconds for all send() calls
 my $session = new IPC::Session("ssh fred",30);
 
 $session->send("hostname");  # run `hostname` command on fred
 print $session->stdout();  # prints "fred"
 $session->send("date");  # run `date` within same ssh
 print $session->stdout();  # prints date
 
 # use like 'expect':
 $session->send("uname -s");
 for ($session->stdout)
 {
 	/IRIX/ && do { $netstat = "/usr/etc/netstat" };
 	/ConvexOS/ && do { $netstat = "/usr/ucb/netstat" };
 	/Linux/ && do { $netstat = "/bin/netstat" };
 }
 
 # errno returned in scalar context:
 $errno = $session->send("$netstat -rn");
 # try this:
 $session->send("grep '^$user:' /etc/passwd") 
	 && warn "$user not there";
 
 # hash returned in array context:
 %netstat = $session->send("$netstat -in");
 print "$netstat{'stdout'}\n";  # prints interface table
 print "$netstat{'stderr'}\n";  # prints nothing (hopefully)
 print "$netstat{'errno'}\n";   # prints 0

=head1 DESCRIPTION

This module encapsulates the open3() function call (see L<IPC::Open3>)
and its associated 
filehandles, making it easy to maintain multiple persistent 'ssh' 
and/or 'rsh' sessions within the same perl script.  

The remote shell session is kept open for the life of the object; this
avoids the overhead of repeatedly opening remote shells via multiple
ssh or rsh calls.  This persistence is particularly useful if you are 
using ssh for your remote shell invocation; it helps you overcome 
the high ssh startup time.

For applications requiring remote command invocation, this module 
provides functionality that is similar to 'expect' or Expect.pm,
but in a lightweight more Perlish package, with discrete STDOUT, 
STDERR, and return code processing.

=head1 METHODS

=head2 my $session = new IPC::Session("ssh fred",30);  

The constructor accepts the command string to be used to open the remote 
shell session, such as ssh or rsh; it also accepts an optional timeout
value, in seconds.  It returns a reference to the unique session object.  

If the timeout is not specified then it defaults to 60 seconds.  
The timeout value can also be changed later; see L<"timeout()">.

=cut

sub new
{
	my $class=shift;
	$class = (ref $class || $class);
	my $self={};
	bless $self, $class;

	my ($cmd,$timeout,$handler)=@_;
	$self->{'handler'} = $handler || sub {die @_};
	$timeout=60 unless defined $timeout;
	$self->{'timeout'} = $timeout;

	local(*IN,*OUT,*ERR);  # so we can use more than one of these objects
	open3(\*IN,\*OUT,\*ERR,$cmd) || &{$self->{'handler'}}($!);
	
	($self->{'stdin'},$self->{'stdout'},$self->{'stderr'}) = (*IN,*OUT,*ERR);
	
	# Set to autoflush.
	for (*IN,*OUT,*ERR) {
		select;
		$|++;
	}
	select STDOUT;

	return $self;
}

=head2 $commandhandle = $session->send("hostname");  

The send() method accepts a command string to be executed on the remote
host.  The command will be executed in the context of the default shell
of the remote user (unless you start a different shell by sending the
appropriate command...).  All shell escapes, command line terminators, pipes, 
redirectors, etc. are legal and should work, though you of course will 
have to escape special characters that have meaning to Perl.

In a scalar context, this method returns the return code produced by the
command string.

In an array context, this method returns a hash containing the return code
as well as the full text of the command string's output from the STDOUT 
and STDERR file handles.  The hash keys are 'stdout', 'stderr', and 
'errno'.

=cut

sub send
{
	my $self=shift;
	my $cmd=join(' ',@_);

	my $out;
	my $outl;
	my $eot="_EoT_" . rand() . "_";
	$self->{'out'}{'errno'}="-666";
	my $stdin = $self->{'stdin'};

	# run command
	print $stdin "$cmd\n";

	# echo end-of-text markers on both stdout and stderr, also get return code
	print $stdin "echo $eot errno=\$?\n";
	print $stdin "echo $eot >&2 \n";

	# snarf the output until we hit eot marker on both streams
	for my $handle ('stdout', 'stderr')
	{
		my $rin = my $win = my $ein = '';
		vec($rin,fileno($self->{$handle}),1) = 1;
		$ein = $rin;

		$out="";
		while (!select(undef,undef,my $eout=$ein,0))  # while !eof()
		{
			$outl = "";
			while (!select(undef,undef,my $eout=$ein,0))  # while !eof()
			{
				# wait for output on handle
				select(my $rout=$rin, undef, undef, $self->{'timeout'}) 
					|| &{$self->{'handler'}}("timeout on $handle");
				# read one char
				sysread($self->{$handle},my $outc,1) 
					|| &{$self->{'handler'}}("read error from $handle");

				$outl .= $outc;
				last if $outc eq "\n";
			}
			last if $outl =~ "$eot";
			$out .= $outl;
		}
		# store snarfed output
		$self->{'out'}{$handle} = $out;
		# store snarfed return code
		$outl =~ /$eot errno=(\d*)/ && ($self->{'out'}{'errno'} = $1);
	}
	return $self->{'errno'} unless wantarray;
	return ( 
			errno => $self->{'out'}{'errno'}, 
			stdout => $self->{'out'}{'stdout'}, 
			stderr => $self->{'out'}{'stderr'}
			);
}

=head2 print $session->stdout();  

Returns the full STDOUT text generated from the last send() command string.

Also available via array context return codes -- see L<"send()">.

=cut

sub stdout
{
	my $self=shift;
	return $self->{'out'}{'stdout'};
}

=head2 print $session->stderr();  

Returns the full STDERR text generated from the last send() command string.

Also available via array context return codes -- see L<"send()">.

=cut

sub stderr
{
	my $self=shift;
	return $self->{'out'}{'stderr'};
}

=head2 print $session->errno();  

Returns the return code generated from the last send() command string.

Also available via array context return codes -- see L<"send()">.

=cut

sub errno  
{
	my $self=shift;
	return $self->{'out'}{'errno'};
}

=head2 $session->timeout(90);  

Allows you to change the timeout for subsequent send() calls.

The timeout value is in seconds.  Fractional seconds are allowed.  
The timeout applies to all send() calls.  

Returns the current timeout.  Can be called with no args.

=cut

sub timeout  
{
	my $self=shift;
	$self->{'timeout'} = ( shift || $self->{'timeout'});
	return $self->{'timeout'};
}

sub handler
{
	my $self=shift;
	$self->{'handler'} = ( shift || $self->{'handler'});
	return $self->{'handler'};
}

=head1 BUGS/RESTRICTIONS

=over 4

=item *

The remote shell command you specify in new() is assumed to not prompt for 
any passwords or present any 
challenge codes; i.e.; you must use .rhosts or the equivalent.  This
restriction may be removed in future versions of this module, but it's 
there now.  

=back

=head1 AUTHOR

 Steve Traugott <stevegt@TerraLuna.Org>

=head1 SEE ALSO

L<IPC::Open3>,
L<rsh(1)>,
L<ssh(1)>,
L<Expect>,
L<expect(1)>

=cut

1;
