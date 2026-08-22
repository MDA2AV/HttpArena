use Mojolicious::Lite -signatures;
use Mojo::JSON qw(decode_json);
use Mojo::Server::Prefork;

# Workers per core, cgroup aware, in the same order koa's getCPUCount reads them:
# the cgroup quota first, then the cpuset the container was actually given.
sub cpu_count {

    # cgroup v2
    if (open my $fh, '<', '/sys/fs/cgroup/cpu.max') {
        chomp(my $line = <$fh> // '');
        close $fh;
        my ($quota, $period) = split ' ', $line;
        if (defined $period && defined $quota && $quota ne 'max' && $period =~ /^[1-9][0-9]*$/) {
            my $n = int($quota / $period);
            return $n if $n >= 1;
        }
    }

    # cgroup v1
    if (open my $qf, '<', '/sys/fs/cgroup/cpu/cpu.cfs_quota_us') {
        chomp(my $quota = <$qf> // '');
        close $qf;
        if (open my $pf, '<', '/sys/fs/cgroup/cpu/cpu.cfs_period_us') {
            chomp(my $period = <$pf> // '');
            close $pf;
            if ($quota =~ /^[1-9][0-9]*$/ && $period =~ /^[1-9][0-9]*$/) {
                my $n = int($quota / $period);
                return $n if $n >= 1;
            }
        }
    }

    # The affinity mask, so a --cpuset-cpus run gets the cores it can really use
    if (open my $fh, '<', '/proc/self/status') {
        my $list;
        while (my $line = <$fh>) {
            $list = $1, last if $line =~ /^Cpus_allowed_list:\s*(\S+)/;
        }
        close $fh;
        if (defined $list) {
            my $n = 0;
            for my $range (split /,/, $list) {
                if ($range =~ /^([0-9]+)-([0-9]+)$/) { $n += $2 - $1 + 1 }
                elsif ($range =~ /^[0-9]+$/)         { $n += 1 }
            }
            return $n if $n >= 1;
        }
    }

    # Every online cpu
    if (open my $fh, '<', '/proc/cpuinfo') {
        my $n = grep { /^processor\s*:/ } <$fh>;
        close $fh;
        return $n if $n >= 1;
    }

    return 1;
}

# Dataset, read once in the manager so the workers share it copy on write.
# A missing or broken file leaves an empty list, it must never stop the server.
my @BASE;    # every field of an item except total
my @UNIT;    # price * quantity, the part of total that does not depend on m
{
    my $file = $ENV{DATASET_PATH} // '/data/dataset.json';
    my $items = eval {
        open my $fh, '<:raw', $file or die "$file: $!";
        local $/;
        decode_json(scalar <$fh>);
    } // [];
    $items = [] unless ref $items eq 'ARRAY';
    for my $d (@$items) {
        push @BASE, {
            id       => $d->{id},
            name     => $d->{name},
            category => $d->{category},
            price    => $d->{price},
            quantity => $d->{quantity},
            active   => $d->{active},
            tags     => $d->{tags},
            rating   => $d->{rating},
        };
        push @UNIT, $d->{price} * $d->{quantity};
    }
}

# Count the request body as it arrives instead of buffering it. /upload takes
# 20 MB bodies, and the stock reader would keep them in memory and then spool
# them to a temp file. The first 4 KB are kept because POST /baseline11 needs
# to read its number back.
app->hook(after_build_tx => sub ($tx, $app) {
    my %arena = (size => 0, head => '');
    $tx->{arena} = \%arena;
    my $req = $tx->req;
    $req->max_message_size(64 * 1024 * 1024);
    $req->content->unsubscribe('read')->on(read => sub ($content, $bytes) {
        $arena{size} += length $bytes;
        $arena{head} .= $bytes if length($arena{head}) < 4096;
    });
});

# parseInt on a string: leading sign and digits, anything else contributes nothing
sub _int ($str) {
    return undef unless defined $str && $str =~ /^\s*([-+]?[0-9]+)/;
    return 0 + $1;
}

sub _sum_query ($c) {
    my $sum   = 0;
    my $pairs = $c->req->url->query->pairs;
    for (my $i = 1; $i < @$pairs; $i += 2) {
        my $n = _int($pairs->[$i]);
        $sum += $n if defined $n;
    }
    return $sum;
}

get '/pipeline' => sub ($c) { $c->render(text => 'ok', format => 'txt') };

my $baseline11 = sub ($c) {
    my $total = _sum_query($c);
    if ($c->req->method eq 'POST') {
        my $n = _int($c->tx->{arena}{head});
        $total += $n if defined $n;
    }
    $c->render(text => "$total", format => 'txt');
};

get '/baseline11'  => $baseline11;
post '/baseline11' => $baseline11;

get '/json/:count' => sub ($c) {
    my $count = _int($c->stash('count')) // 0;
    $count = 0      if $count < 0;
    $count = @BASE  if $count > @BASE;
    my $m = _int($c->req->url->query->param('m')) || 1;
    my @items;
    for my $i (0 .. $count - 1) {
        push @items, {%{$BASE[$i]}, total => $UNIT[$i] * $m};
    }

    # json-comp is the renderer's own gzip negotiation, nothing hand rolled
    $c->render(json => {items => \@items, count => $count});
};

post '/upload' => sub ($c) {
    my $size = $c->tx->{arena}{size};
    $c->render(text => "$size", format => 'txt');
};

app->log->level('info');

# json-tls on 8081: the same app, over Mojo's own TLS listener. The harness
# mounts /certs for the TLS profiles only, so without them only 8080 is opened
# -- Mojo aborts at startup on a listen URL naming certificate files that are
# not there.
my @listen = ('http://*:8080');
if (-f '/certs/server.crt' && -f '/certs/server.key') {
    push @listen, 'https://*:8081?cert=/certs/server.crt&key=/certs/server.key';
}

Mojo::Server::Prefork->new(
    app     => app,
    listen  => \@listen,
    workers => cpu_count(),

    # A worker is not recycled in the middle of a run: limited-conn opens a new
    # connection every 10 requests, and the stock 10000 accepts would restart
    # every worker several times during the measurement.
    accepts => 0,

    # Same reason on the keep alive side, the stock limit closes a connection
    # after 100 requests and the profiles reuse them for the whole run.
    max_requests => 1_000_000_000,

    # json-comp opens 16384 connections, so leave room above the 1000 per
    # worker the event loop allows by default.
    max_clients => 4096,
)->run;
