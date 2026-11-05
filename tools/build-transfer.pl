#!/usr/bin/env perl
# =====================================================================
#  王国移民ページ生成スクリプト（MightPulse API）
#
#  使い方:
#     perl tools/build-transfer.pl
#
#  ・掲載する王国とKvK情報は data/transfer-kvk.json に書きます
#    （APIのKvK情報は有料なので、Kingshot Optimizer の値を手で入れています）
#  ・先頭の王国（1899）を比較の基準にして、一覧の先頭に固定します
#  ・出力先は event-transfer.html です
#
#  APIキーは ~/.mightpulse_key から読み込みます（リポジトリには入れない）
# =====================================================================
use strict;
use warnings;
use utf8;
use JSON::PP;
use POSIX qw(strftime);
use Time::HiRes qw(sleep);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $OUT     = 'event-transfer.html';
my $KVKFILE = 'data/transfer-kvk.json';
my $API     = 'https://api.mightpulse.com/v1';
my $SITE    = 'https://mightpulse.com';
my $TOP_ALLIANCES = 5;   # 詳細に載せる同盟の数

my $keyfile = "$ENV{HOME}/.mightpulse_key";
open(my $kf, '<', $keyfile) or die "APIキーが読めません: $keyfile\n";
my $key = <$kf>; close $kf; $key =~ s/\s+$//;

# ---------- 共通ユーティリティ ----------
sub api_once {
    my ($path) = @_;
    # シェルを通さずに curl を起動する
    open(my $fh, '-|', 'curl', '-s', '--max-time', '30',
         '-H', "Authorization: Bearer $key", "$API$path")
        or die "curl を起動できません: $!\n";
    my $json = do { local $/; <$fh> };
    close $fh;
    my $d = eval { decode_json($json // '') };
    return ($d && $d->{ok}) ? $d : undef;
}
sub api {
    my ($path) = @_;
    for my $try (1 .. 3) {
        my $d = api_once($path);
        return $d if $d;
        sleep 3;
    }
    die "APIリクエスト失敗: $path\n";
}
sub fmt {
    my ($n) = @_;
    return '—' unless defined $n && $n =~ /^-?\d+(\.\d+)?$/;
    return sprintf('%.1fB', $n / 1_000_000_000) if abs($n) >= 1_000_000_000;
    return sprintf('%.1fM', $n / 1_000_000)     if abs($n) >= 1_000_000;
    return scalar reverse join(',', unpack('(A3)*', reverse int($n)));
}
sub esc {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}
sub val  { my ($s) = @_; return (defined $s && $s ne '') ? esc($s) : '—'; }
sub num  { my ($n) = @_; return (defined $n && $n =~ /^-?\d+$/) ? $n : '—'; }
sub num0 { my ($n) = @_; return (defined $n && $n =~ /^-?\d+(\.\d+)?$/) ? $n : 0; }

# 画像タグ（読み込めなければ自動で消える）
sub img_tag {
    my ($u) = @_;
    return '' unless defined $u && $u ne '';
    $u = $SITE . $u if $u =~ m{^/};
    return '' unless $u =~ m{^https?://};
    return qq{<img class="mk" src="@{[esc $u]}" alt="" loading="lazy" onerror="this.remove()">};
}

# ---------- 掲載する王国とKvK情報 ----------
open(my $jf, '<:raw', $KVKFILE) or die "読めません: $KVKFILE\n";
my $kvk = decode_json(do { local $/; <$jf> });
close $jf;

my @list = @{ $kvk->{kingdoms} };
die "王国が登録されていません: $KVKFILE\n" unless @list;
for my $e (@list) {
    die "kid は数字で指定してください: $e->{kid}\n" unless $e->{kid} =~ /^\d+$/;
}

# ---------- 取得 ----------
for my $e (@list) {
    my $kid = $e->{kid};
    print "$kid を取得中...\n";
    $e->{k}         = api("/kingdoms/$kid")->{kingdom};
    sleep 0.2;
    $e->{players}   = api("/kingdoms/$kid/ranks?board=personal_power&limit=100")->{boards}[0]{rows} // [];
    sleep 0.2;
    $e->{alliances} = api("/kingdoms/$kid/ranks?board=alliance_power&limit=$TOP_ALLIANCES")->{boards}[0]{rows} // [];
    sleep 0.2;
}
my $captured = strftime('%Y/%m/%d %H:%M', localtime);
my $us = $list[0];

sub kname {
    my ($e) = @_;
    my $n = $e->{k}{name};
    return (defined $n && $n ne '') ? esc($n) : "$e->{kid}サーバー";
}
sub record { my ($r) = @_; return num($r->[0]) . '勝' . num($r->[1]) . '敗（' . sprintf('%.2f', num0($r->[2])) . '）'; }
sub better { my ($v, $base, $is_us) = @_; return (!$is_us && num0($v) > num0($base)) ? ' class="better"' : ''; }

# ---------- 一覧表 ----------
my $list_html = '';
for my $e (@list) {
    my $is_us = $e == $us;
    my ($k, $u) = ($e->{k}, $us->{k});
    my $tr = $is_us ? ' class="us"' : '';
    my $gain = fmt($k->{power_gain_7d});
    $gain = "+$gain" if num0($k->{power_gain_7d}) > 0;
    $list_html .= sprintf(
        qq{            <tr%s><td class="kid">%s</td><td%s>%s人</td><td%s>%s</td><td%s>%s</td><td%s>%s</td><td%s>%s</td></tr>\n},
        $tr, num($e->{kid}),
        better($k->{active_7d}, $u->{active_7d}, $is_us), fmt($k->{active_7d}),
        better($k->{power_gain_7d}, $u->{power_gain_7d}, $is_us), $gain,
        better($e->{prep}[2], $us->{prep}[2], $is_us), record($e->{prep}),
        better($e->{battle}[2], $us->{battle}[2], $is_us), record($e->{battle}),
        better($k->{power}, $u->{power}, $is_us), fmt($k->{power}),
    );
}

# ---------- 王国ごとの詳細 ----------
my $floor = @{ $us->{players} } ? $us->{players}[-1]{score} : 0;   # 1899の100位の戦力

sub score_at {
    my ($e, $rank) = @_;
    my $r = $e->{players}[$rank - 1];
    return $r ? fmt($r->{score}) : '—';
}

sub render_kingdom {
    my ($e) = @_;
    my $k    = $e->{k};
    my $name = kname($e);

    # 上位100人の同盟ごとの人数
    my %in_top;
    my $no_alliance = 0;
    for my $p (@{ $e->{players} }) {
        my $tag = $p->{alliance_abbr};
        if (defined $tag && $tag ne '') { $in_top{$tag}++ } else { $no_alliance++ }
    }
    my $over  = grep { $_->{score} >= $floor } @{ $e->{players} };
    my $count = $over >= 100 ? '100人以上' : "${over}人";

    my $bands = '';
    for my $rank (1, 10, 50, 100) {
        $bands .= qq{              <tr><td class="rk">${rank}位</td><td class="num">@{[score_at($e, $rank)]}</td><td class="num">@{[score_at($us, $rank)]}</td></tr>\n};
    }

    my $al_rows = '';
    for my $a (@{ $e->{alliances} }) {
        my $tag = $a->{abbr};
        $al_rows .= sprintf(
            qq{              <tr><td class="rk">%s</td><td class="who">%s<span class="al-tag">%s</span></td><td class="who name-cell">%s</td><td class="who name-cell">%s</td><td class="num">%s</td><td class="num">%s</td><td class="num">%s</td></tr>\n},
            num($a->{rank}), img_tag($a->{flag_url}), val($tag), val($a->{name}), val($a->{leader_name}),
            fmt($a->{score}), num($a->{member_count}),
            (defined $tag ? ($in_top{$tag} // 0) : 0) . '人',
        );
    }

    my $last = $e->{last};
    return <<"HTML";
      <details class="acc">
        <summary>🏰 $name</summary>
        <div class="acc-body">
          <h3>📌 基本情報</h3>
          <div class="kstat-grid">
            <div class="kstat"><span class="kstat-label">🎂 開設日</span><span class="kstat-value">@{[val($k->{opened_on})]}（@{[fmt($k->{age_days})]}日目）</span></div>
            <div class="kstat"><span class="kstat-label">👥 プレイヤー数</span><span class="kstat-value">@{[fmt($k->{player_count})]}人</span></div>
            <div class="kstat"><span class="kstat-label">📊 平均戦力</span><span class="kstat-value">@{[fmt($k->{avg_power})]}</span></div>
          </div>

          <h3>⚔️ 直近のKvK</h3>
          <div class="kstat-grid">
            <div class="kstat"><span class="kstat-label">対戦相手</span><span class="kstat-value">@{[num($last->{opponent})]}サーバー</span></div>
            <div class="kstat"><span class="kstat-label">KvK準備</span><span class="kstat-value">@{[val($last->{prep})]}</span></div>
            <div class="kstat"><span class="kstat-label">KvK戦争</span><span class="kstat-value">@{[val($last->{battle})]}</span></div>
          </div>

          <h3>💪 上位プレイヤーの戦力帯</h3>
          <div class="table-wrap">
            <table class="rank-table band-table">
              <thead><tr><th>順位</th><th>$e->{kid}</th><th>$us->{kid}</th></tr></thead>
              <tbody>
$bands              </tbody>
            </table>
          </div>
          <div class="kstat-grid">
            <div class="kstat"><span class="kstat-label">$us->{kid}の100位以上の人数</span><span class="kstat-value">$count</span></div>
            <div class="kstat"><span class="kstat-label">上位100人の無所属</span><span class="kstat-value">${no_alliance}人</span></div>
          </div>

          <h3>🏰 同盟の状況</h3>
          <div class="table-wrap">
            <table class="rank-table">
              <thead><tr><th>順位</th><th>同盟</th><th class="name-cell">同盟名</th><th class="name-cell">盟主</th><th>戦力</th><th>人数</th><th>上位100人</th></tr></thead>
              <tbody>
$al_rows              </tbody>
            </table>
          </div>
        </div>
      </details>

HTML
}

my $detail_html = '';
$detail_html .= render_kingdom($_) for @list[1 .. $#list];

my $kvk_when = esc($kvk->{updated});
my $kvk_no   = num($kvk->{kvk_no});

# ---------- ページ全体 ----------
my $html = <<"PAGE";
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="robots" content="noindex, nofollow">
  <title>王国移民｜イベント情報｜CGY 攻略Wiki</title>
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="site-header">
    <a class="brand" href="index.html">
      <span class="logo">🐾</span>
      <span><span class="cgy">CGY</span> 攻略Wiki</span>
    </a>
    <p class="tagline">CritterGangYard 同盟メンバー専用 ／ キングショット攻略まとめ</p>
  </header>

  <nav class="nav">
    <a href="index.html">ホーム</a>
    <a href="basics.html">基本的な情報</a>
    <a href="events.html" class="active">イベント情報</a>
    <a href="heroes.html">英雄育成</a>
    <a href="battle.html">戦闘・編成</a>
  </nav>

  <main>
    <p class="crumb"><a href="events.html">← イベント情報一覧へ</a></p>

    <section class="hero">
      <h1>🧳 王国移民</h1>
      <p>王国ごとの情報をまとめています。🐾</p>
    </section>

    <section class="card">
      <h2>📊 王国一覧</h2>
      <div class="table-wrap">
        <table class="rank-table transfer-table">
          <thead>
            <tr><th>王国</th><th>アクティブ(7日)</th><th>7日の伸び</th><th>KvK準備</th><th>KvK戦争</th><th>総戦力</th></tr>
          </thead>
          <tbody>
$list_html          </tbody>
        </table>
      </div>
      <p class="mini-note"><span class="better-chip"></span>$us->{kid}より数値が良いセル</p>
      <p class="mini-note">※（　）内はポイントです。</p>
      <p class="mini-note">※ データ取得：$captured 時点（MightPulse API）／KvKは KvK $kvk_no まで（$kvk_when 更新・@{[esc $kvk->{source}]}）</p>
    </section>

    <section class="cat">
      <h2 class="cat-title">🏰 各王国の詳細</h2>

$detail_html    </section>
  </main>

  <footer class="site-footer">
    <p class="paws">🐾 🐾 🐾</p>
    <p>CGY - CritterGangYard 同盟メンバー専用サイト<br>
       ※このサイトは限定公開です。URLの共有はメンバー内のみでお願いします。</p>
  </footer>
</body>
</html>
PAGE

open(my $fh, '>:encoding(UTF-8)', $OUT) or die "書き込めません: $OUT\n";
print $fh $html;
close $fh;

print "\n✅ 生成しました: $OUT（", scalar(@list), "王国・$captured 時点）\n";
