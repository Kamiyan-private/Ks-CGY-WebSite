#!/usr/bin/perl
# プレビュー用のローカルサーバー（Python が使えないので Perl で立てる）
# 使い方：perl tools/serve.pl [ポート番号]（省略時 8766）→ http://127.0.0.1:8766/
use strict;
use warnings;
use IO::Socket::INET;
use FindBin;

my $port = shift || 8766;
my $root = "$FindBin::Bin/..";
my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 10, ReuseAddr => 1)
  or die "ポート $port を開けません（使用中かも）: $!\n";
$| = 1;
print "serving $root on http://127.0.0.1:$port/\n";

my %type = (
  html => 'text/html; charset=UTF-8', css => 'text/css', js => 'application/javascript',
  json => 'application/json', webp => 'image/webp', png => 'image/png', jpg => 'image/jpeg',
  svg => 'image/svg+xml', ico => 'image/x-icon', txt => 'text/plain; charset=UTF-8',
);

# ブラウザは何も送らない先読み接続を張ることがあるので、接続ごとに子プロセスで処理する
# （1本で順番に処理すると、その接続を待ったまま固まる）
$SIG{CHLD} = 'IGNORE';
while (1) {
  my $c = $s->accept or next;
  my $pid = fork;
  if (!defined $pid) { close $c; next }
  if ($pid) { close $c; next }
  close $s;
  local $SIG{ALRM} = sub { exit 0 };
  alarm 10;
  handle($c);
  exit 0;
}

sub handle {
  my ($c) = @_;
  my $line = <$c> // '';
  while (my $h = <$c>) { last if $h =~ /^\r?\n$/ }
  my ($path) = $line =~ m{^GET (\S+)};
  $path //= '/';
  $path =~ s/[?#].*//;
  $path =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
  $path = '/index.html' if $path eq '/';
  if ($path =~ /\.\./) { print $c "HTTP/1.0 403 Forbidden\r\n\r\n"; close $c; return }
  my $file = "$root$path";
  if (open my $fh, '<:raw', $file) {
    local $/;
    my $data = <$fh>;
    my ($ext) = $file =~ /\.(\w+)$/;
    print $c "HTTP/1.0 200 OK\r\nContent-Type: " . ($type{lc($ext // '')} // 'application/octet-stream')
      . "\r\nCache-Control: no-store\r\nContent-Length: " . length($data) . "\r\n\r\n" . $data;
  } else {
    print $c "HTTP/1.0 404 Not Found\r\n\r\n";
  }
  close $c;
}
