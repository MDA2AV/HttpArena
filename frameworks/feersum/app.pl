use v5.40;
use warnings;
use Feersum::Runner;
use EV;
use JSON::XS ();
use Gzip::Faster ();
use URL::Encode qw(url_params_flat);
use Data::Util qw(is_integer);
use Router::Ragel;
use Text::Stencil ();
use EV::Pg ();
use EV::Websockets ();

use constant {
    text      => [qw'Content-Type text/plain'],
    json      => [qw'Content-Type application/json'],
    json_gzip => [qw'Content-Type application/json Content-Encoding gzip'],
    html      => ['Content-Type', 'text/html; charset=utf-8'],
    bin       => [qw'Content-Type application/octet-stream'],
};

my $empty_body = '';
my $ok_body    = 'ok';
my $json       = JSON::XS->new->utf8;
my $gzip       = Gzip::Faster->new;
$gzip->level(1);
my ($ws_ctx, %ws_conns);
sub get_ws_ctx {
    $ws_ctx //= eval { EV::Websockets::Context->new(ssl_init => 0) };
}

my %mime = (
    css   => 'text/css',
    js    => 'application/javascript',
    html  => 'text/html',
    json  => 'application/json',
    woff2 => 'font/woff2',
    svg   => 'image/svg+xml',
    webp  => 'image/webp',
);

sub cpu_count {
    if (open my $fh, '<', '/sys/fs/cgroup/cpu.max') {
        my ($quota, $period) = split ' ', (<$fh> // '');
        if ($quota && $period && $quota ne 'max' && $period > 0) {
            my $n = int($quota / $period);
            return $n if $n >= 1;
        }
    }
    if (open my $qf, '<', '/sys/fs/cgroup/cpu/cpu.cfs_quota_us') {
        my $quota = <$qf> // 0;
        if (open my $pf, '<', '/sys/fs/cgroup/cpu/cpu.cfs_period_us') {
            my $period = <$pf> // 0;
            if ($quota > 0 && $period > 0) {
                my $n = int($quota / $period);
                return $n if $n >= 1;
            }
        }
    }
    if (open my $fh, '<', '/proc/self/status') {
        while (<$fh>) {
            if (/^Cpus_allowed_list:\s*(\S+)/) {
                my $n = 0;
                for (split /,/, $1) {
                    $n += /^(\d+)-(\d+)$/ ? $2 - $1 + 1 : 1;
                }
                return $n if $n >= 1;
            }
        }
    }
    return `nproc` + 0 || 1;
}

my $cpus = cpu_count();
my $pool_size = do {
    my $tot = $ENV{DATABASE_MAX_CONN} || 256;
    my $v = int($tot / $cpus);
    $v < 2 ? 2 : $v > 64 ? 64 : $v;
};

my (@base, @unit);
{
    my $file = $ENV{DATASET_PATH} // '/data/dataset.json';
    my $items = eval {
        open my $fh, '<:raw', $file or die "$file: $!";
        local $/;
        $json->decode(scalar <$fh>);
    } // [];
    $items = [] unless ref $items eq 'ARRAY';
    for my $d (@$items) {
        push @base, {
            id       => $d->{id},
            name     => $d->{name},
            category => $d->{category},
            price    => $d->{price},
            quantity => $d->{quantity},
            active   => $d->{active},
            tags     => $d->{tags},
            rating   => $d->{rating},
            total    => 0,
        };
        push @unit, $d->{price} * $d->{quantity};
    }
}

sub sum_query ($qs) {
    return 0 unless defined $qs && length $qs;
    my $flat = url_params_flat($qs);
    my $sum = 0;
    for (my $i = 1; $i < @$flat; $i += 2) {
        $sum += 0 + is_integer($flat->[$i]) ? $flat->[$i] : 0;
    }
    return $sum;
}

sub parse_db_params ($qs) {
    my ($min, $max, $limit) = (10, 50, 50);
    if (defined $qs && length $qs) {
        my $flat = url_params_flat($qs);
        for (my $i = 0; $i < @$flat; $i += 2) {
            my $k = $flat->[$i];
            my $v = $flat->[$i + 1];
            if ($k eq 'min') {
                $min = $v if 0 + is_integer($v);
            } elsif ($k eq 'max') {
                $max = $v if 0 + is_integer($v);
            } elsif ($k eq 'limit') {
                $limit = $v if 0 + is_integer($v);
            }
        }
    }
    $limit = 1 if $limit < 1;
    $limit = 50 if $limit > 50;
    return ($min, $max, $limit);
}

sub read_body ($h) {
    my $body = '';
    if (my $input = $h->input) {
        my $cl = $h->content_length;
        if (defined $cl && $cl > 0) {
            $input->read($body, $cl);
        } else {
            while ($input->read(my $chunk, 65536)) {
                $body .= $chunk;
            }
        }
    }
    if (my $ce = $h->header('Content-Encoding')) {
        $body = $gzip->unzip($body) if $ce =~ /gzip/i;
    }
    return $body;
}

my $fortune_tpl = Text::Stencil->new(
    header => '<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr>',
    row    => '<tr><td>{0:int}</td><td>{1:html}</td></tr>',
    footer => '</table></body></html>',
);
my $extra_fortune = [0, 'Additional fortune added at request time.'];

my $noop = sub {};
my $db_url = $ENV{DATABASE_URL};
my (@pool, $pi, $prepare_w, %dirty, @db_waiters);

my $drain_waiters = sub {
    while (@db_waiters && @pool) {
        my $cb = shift @db_waiters;
        my $c = $pool[$pi % @pool];
        $pi = ($pi + 1) % @pool;
        $cb->($c);
    }
};

my $init_db = sub {
    return unless $db_url;
    @pool = (); $pi = 0; %dirty = ();
    $prepare_w = EV::prepare sub {
        if (%dirty) {
            my @conns = values %dirty;
            %dirty = ();
            $_->sync($noop) for @conns;
        }
    };
    my $make_conn; $make_conn = sub {
        return if @pool >= $pool_size;
        my $retry = sub { my $t; $t = EV::timer 2, 0, sub { undef $t; $make_conn->() } };
        my $c;
        eval {
            $c = EV::Pg->new(
                conninfo => $db_url,
                on_connect => sub {
                    $c->enter_pipeline;
                    $c->prep(async_db => <<~\sql, $noop);
                        select
                            id,
                            name,
                            category,
                            price,
                            quantity,
                            active,
                            tags,
                            rating_score,
                            rating_count
                        from items
                        where price between $1 and $2
                        limit $3
                        sql
                    $c->prep(fortunes => <<~\sql, $noop);
                        select
                            id,
                            message
                        from fortune
                        sql
                    $c->sync(sub {
                        push @pool, $c;
                        $drain_waiters->();
                    });
                },
                on_error => sub {
                    warn "pg: @_";
                    @pool = grep { "$_" ne "$c" } @pool;
                    $retry->();
                },
            );
        };
        if ($@) {
            warn $@;
            $retry->();
        }
    };
    $make_conn->() for 1 .. $pool_size;
};

sub with_db ($cb) {
    if (@pool) {
        my $c = $pool[$pi % @pool];
        $pi = ($pi + 1) % @pool;
        $cb->($c);
    } elsif (!$db_url) {
        $cb->(undef);
    } else {
        push @db_waiters, $cb;
    }
}

my $fallback = sub ($h, @) {
    return $h->send_response(404, text, $empty_body);
};

my $router = Router::Ragel->new
    ->add('/pipeline', sub ($h, @) {
        return $h->send_response(200, text, $ok_body);
    })
    ->add('/baseline11', sub ($h, @) {
        my $sum = sum_query($h->query);
        if ($h->method eq 'POST') {
            my $body = read_body($h);
            $sum += 0 + is_integer($body) ? $body : 0;
        }
        return $h->send_response(200, text, "$sum");
    })
    ->add('/baseline2', sub ($h, @) {
        return $h->send_response(200, text, \("" . sum_query($h->query)));
    })
    ->add('/json/:count<int>', sub ($h, $count = 0) {
        $count = 0     if $count < 0;
        $count = @base if $count > @base;
        my $m = 1;
        if (defined(my $q = $h->query)) {
            my $flat = url_params_flat($q);
            for (my $i = 0; $i < @$flat; $i += 2) {
                if ($flat->[$i] eq 'm') {
                    $m = (0 + is_integer($flat->[$i + 1]) ? $flat->[$i + 1] : 1) || 1;
                    last;
                }
            }
        }
        for (0 .. $count - 1) {
            $base[$_]{total} = $unit[$_] * $m;
        }
        my $payload = qq[{"items":] . $json->encode([ @base[0 .. $count - 1] ]) . qq[,"count":$count}];

        if (my $ae = $h->header('Accept-Encoding')) {
            return $h->send_response(200, json_gzip, $gzip->zip($payload)) if $ae =~ /gzip/i;
        }
        return $h->send_response(200, json, $payload);
    })
    ->add('/delay/:ms<int>', sub ($h, $ms = 0) {
        if ($ms <= 0) {
            return $h->send_response(200, text, '0');
        }
        my $t;
        $t = EV::timer $ms / 1000, 0, sub {
            $h->send_response(200, text, "$ms");
            undef $t;
        };
        return;
    })
    ->add('/echo', sub ($h, @) {
        if ($h->method eq 'POST') {
            return $h->send_response(200, bin, read_body($h));
        }
        return $h->send_response(404, text, $empty_body);
    })
    ->add('/static/:file', sub ($h, $file) {
        return $h->send_response(404, text, $empty_body)
            if index($file, '/') >= 0 || index($file, '..') >= 0;
        my $path = "/data/static/$file";
        open my $fh, '<:raw', $path or return $h->send_response(404, text, $empty_body);
        local $/;
        my $content = <$fh>;
        close $fh;
        my ($ext) = ($file =~ /\.([^.]+)$/);
        my $ct = $mime{$ext // ''} // 'application/octet-stream';
        return $h->send_response(200, ['Content-Type', $ct], \$content);
    })
    ->add('/async-db', sub ($h, @) {
        with_db(sub ($c) {
            unless ($c) {
                return $h->send_response(200, json, \'{"items":[],"count":0}');
            }
            my ($min, $max, $limit) = parse_db_params($h->query);
            $c->qx(async_db => [$min, $max, $limit], sub ($rows, $err = undef) {
                if ($err || !$rows || !@$rows) {
                    $h->send_response(200, json, \'{"items":[],"count":0}');
                    return;
                }
                my @items;
                for my $r (@$rows) {
                    push @items, '{"id":' . $r->[0] . ',"name":' . $json->encode($r->[1])
                               . ',"category":' . $json->encode($r->[2])
                               . ',"price":' . $r->[3] . ',"quantity":' . $r->[4]
                               . ',"active":' . ($r->[5] eq 't' || $r->[5] eq '1' ? 'true' : 'false')
                               . ',"tags":' . $r->[6]
                               . ',"rating":{"score":' . $r->[7] . ',"count":' . $r->[8] . '}}';
                }
                my $out = '{"items":[' . join(',', @items) . '],"count":' . scalar(@items) . '}';
                $h->send_response(200, json, \$out);
            });
            $dirty{"$c"} = $c;
        });
    })
    ->add('/fortunes', sub ($h, @) {
        with_db(sub ($c) {
            unless ($c) {
                return $h->send_response(503, text, $empty_body);
            }
            $c->qx(fortunes => [], sub ($rows, $err = undef) {
                if ($err || !$rows) {
                    $h->send_response(503, text, $empty_body);
                    return;
                }
                push @$rows, $extra_fortune;
                my $html = $fortune_tpl->render_sorted($rows, 1);
                $h->send_response(200, html, \$html);
            });
            $dirty{"$c"} = $c;
        });
    })
    ->add('/ws', sub ($h, @) {
        if (my $up = $h->header('Upgrade')) {
            if ($up =~ /websocket/i && (my $ctx = get_ws_ctx())) {
                my $env = $h->env;
                my $path = $h->path;
                my $hdr = "GET $path HTTP/1.1\r\n";
                for (sort keys %$env) {
                    next unless /^HTTP_(.+)/;
                    (my $k = $1) =~ s/_/-/g;
                    $hdr .= "$k: $env->{$_}\r\n";
                }
                $hdr .= "\r\n";
                my $c;
                $c = $ctx->adopt(
                    fh => $h->io,
                    initial_data => $hdr,
                    on_connect => sub ($conn, @) {
                        $ws_conns{"$conn"} = $conn;
                    },
                    on_message => sub ($conn, $data, $is_binary, @) {
                        $is_binary ? $conn->send_binary($data) : $conn->send($data);
                    },
                    on_close => sub ($conn, @) {
                        delete $ws_conns{"$conn"};
                    },
                    on_error => sub ($conn, @) {
                        delete $ws_conns{"$conn"};
                    },
                );
                $ws_conns{"$c"} = $c if $c;
                return;
            }
        }
        return $h->send_response(400, text, $empty_body);
    })
    ->compile;

my $cert_file = '/certs/server.crt';
my $key_file  = '/certs/server.key';
my $has_certs = -f $cert_file && -f $key_file;

no warnings 'redefine';
*Feersum::Runner::_apply_tls_to_listeners = sub ($self, $f, $n_listeners, $tls, $sni = undef) {
    if ($n_listeners > 1) {
        $f->set_tls(listener => 1, cert_file => $tls->{cert_file}, key_file => $tls->{key_file}, h2 => 0);
    }
    if ($n_listeners > 2) {
        $f->set_tls(listener => 2, cert_file => $tls->{cert_file}, key_file => $tls->{key_file}, h2 => 1);
    }
};

my @listen = ('[::]:8080');
push @listen, '[::]:8081', '[::]:8443' if $has_certs;
my $tls_opt = $has_certs ? { cert_file => $cert_file, key_file => $key_file } : undef;

Feersum::Runner->new(
    listen              => \@listen,
    ($tls_opt ? (tls    => $tls_opt) : ()),
    pre_fork            => $cpus,
    after_fork          => sub { undef $ws_ctx; %ws_conns = (); $init_db->() },
    reuseport           => 1,
    quiet               => 1,
    keepalive           => 1,
    max_connection_reqs => 0,
    read_timeout        => 60,
)->run(sub ($h) {
    my ($handler, @cap) = Router::Ragel::match($router, $h->path);
    return ($handler // $fallback)->($h, @cap);
});
