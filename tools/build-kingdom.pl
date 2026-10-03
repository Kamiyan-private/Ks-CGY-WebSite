#!/usr/bin/env perl
# =====================================================================
#  敵鯖ページ生成スクリプト（MightPulse API）
#
#  使い方:
#     perl tools/build-kingdom.pl <kid> <出力ファイル> [対戦期間ラベル] [--reset-baseline]
#  例:
#     perl tools/build-kingdom.pl 1909 event-kingdom-xxxx.html "10/5週"
#
#  ・サーバー概要は自軍（1899）と横並びで比較表示します
#  ・初回実行時のデータを「初期版」として data/kingdom-<kid>-baseline.json に保存し、
#    2回目以降は初期版を据え置いたまま最新版だけ更新します
#  ・初期版を取り直したいときは --reset-baseline を付けて実行してください
#
#  APIキーは ~/.mightpulse_key から読み込みます（リポジトリには入れない）
# =====================================================================
use strict;
use warnings;
use utf8;
use JSON::PP;
use POSIX qw(strftime);
use Encode qw(decode);
use File::Path qw(make_path);

binmode(STDOUT, ':encoding(UTF-8)');

my @args = @ARGV;
my $reset = grep { $_ eq '--reset-baseline' } @args;
@args = grep { $_ ne '--reset-baseline' } @args;

my $kid  = shift @args or die "kid を指定してください（例: 1909）\n";
my $out  = shift @args or die "出力ファイルを指定してください\n";
my $term = shift @args // '';
$term = decode('UTF-8', $term) unless utf8::is_utf8($term);

my $keyfile = "$ENV{HOME}/.mightpulse_key";
open(my $kf, '<', $keyfile) or die "APIキーが読めません: $keyfile\n";
my $key = <$kf>; close $kf; $key =~ s/\s+$//;

# APIの英雄名（英語）→ サイトの日本語表記。
# image/<日本語名>.webp があればその画像を、無ければAPIのアイコンを使う
my %HERO_JA = (
    'Amadeus' => 'アマデウス',  'Zoe'     => 'ゾーイ',    'Eric'    => 'エリック',
    'Perla'   => 'ペーラ',      'Marin'   => 'マリン',    'Jaeger'  => 'イェーガー',
    'Hilde'   => 'ヒルデ',      'Jabel'   => 'ジェベル',  'Saro'    => 'サロ',
    'Helga'   => 'ヘルガ',      'Howard'  => 'ハワード',  'Chenko'  => 'チェンコ',
);

my $API       = 'https://api.mightpulse.com/v1';
my $FLAG_BASE = 'https://mightpulse.com';
my $OUR_KID   = 1899;                                  # 自軍サーバー（CGY）
my $BASELINE  = "data/kingdom-$kid-baseline.json";     # 初期版の保存先

# ---------- 共通ユーティリティ ----------
sub api {
    my ($path) = @_;
    my $json = `curl -s --max-time 30 -H "Authorization: Bearer $key" "$API$path"`;
    die "APIリクエスト失敗: $path\n" unless $json;
    my $d = eval { decode_json($json) };
    die "JSONの解析に失敗: $path\n" unless $d;
    die "APIエラー: $path → " . ($d->{error} // '不明') . "\n" unless $d->{ok};
    return $d;
}
sub fmt {
    my ($n) = @_;
    return '—' unless defined $n;
    return sprintf('%.1fB', $n / 1_000_000_000) if $n >= 1_000_000_000;
    return sprintf('%.1fM', $n / 1_000_000)     if $n >= 1_000_000;
    return scalar reverse join(',', unpack('(A3)*', reverse int($n)));
}
sub esc {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}
sub val    { my ($s) = @_; return (defined $s && $s ne '') ? esc($s) : '—'; }

# APIは絶対URL（CDN）と相対パス（/assets/...）の両方を返すので、相対ならドメインを補う
sub abs_url {
    my ($u) = @_;
    return '' unless defined $u && $u ne '';
    return $u if $u =~ m{^https?://};   # すでに絶対URL
    return $u unless $u =~ m{^/};       # サイト内の相対パス（image/... など）はそのまま
    return $FLAG_BASE . $u;             # APIの相対パス（/assets/...）だけドメインを補う
}
# 画像タグ（読み込めなければ自動で消える）
sub img_tag {
    my ($u) = @_;
    my $src = abs_url($u);
    return '' unless $src;
    return qq{<img class="mk" src="@{[esc $src]}" alt="" loading="lazy" onerror="this.remove()">};
}

# 英雄セル：日本語名 ＋ 画像（サイト内の画像を優先、無ければAPIのアイコン）
sub hero_cell {
    my ($r) = @_;
    my $en = $r->{hero_name};
    return '—' unless defined $en && $en ne '';
    my $ja  = $HERO_JA{$en} // $en;
    # サイト内に日本語名の画像があればそれを優先、無ければAPIのアイコン
    my $img = (-f "image/$ja.webp") ? img_tag("image/$ja.webp") : img_tag($r->{hero_icon});
    return $img . esc($ja);
}
sub medal  { my $r = shift; return $r == 1 ? '🥇' : $r == 2 ? '🥈' : $r == 3 ? '🥉' : $r; }
sub toprow { my $r = shift; return $r <= 3 ? qq{ class="top$r"} : ''; }
sub when   { my $t = shift; return $t ? strftime('%Y/%m/%d %H:%M', localtime(int($t))) : '—'; }

# ---------- 取得する部門 ----------
my @BOARDS = (
    { key => 'personal_power', icon => '💪', label => '個人総力',   unit => '戦力'   },
    { key => 'mystic_trial',   icon => '🗺️', label => '秘境の試練', unit => 'スコア' },
    { key => 'single_hero',    icon => '🦸', label => '英雄総力',   unit => '戦力'   },
    { key => 'alliance_power', icon => '🏰', label => '同盟総力',   unit => '戦力'   },
);

# ---------- ランキング表を1つ描画 ----------
sub render_board {
    my ($meta, $rows, $indent) = @_;
    my $pad = ' ' x $indent;
    my $body = '';

    if ($meta->{kind} && $meta->{kind} eq 'alliance') {
        for my $r (@$rows) {
            my $img = img_tag($r->{flag_url});
            $body .= sprintf(
                qq{%s        <tr%s><td class="rk">%s</td><td class="num">%s</td><td class="who">%s<span class="al-tag">%s</span></td><td class="who name-cell">%s</td><td class="who name-cell">%s</td><td class="num">%s</td></tr>\n},
                $pad, toprow($r->{rank}), medal($r->{rank}), fmt($r->{score}),
                $img, val($r->{abbr}), val($r->{name}), val($r->{leader_name}), $r->{member_count} // '—'
            );
        }
        return <<"HTML";
$pad<details class="acc">
$pad  <summary>$meta->{icon} $meta->{label}</summary>
$pad  <div class="acc-body">
$pad    <div class="table-wrap">
$pad      <table class="rank-table">
$pad        <thead>
$pad          <tr><th>順位</th><th>$meta->{unit}</th><th>同盟</th><th class="name-cell">同盟名</th><th class="name-cell">盟主</th><th>人数</th></tr>
$pad        </thead>
$pad        <tbody>
$body$pad        </tbody>
$pad      </table>
$pad    </div>
$pad  </div>
$pad</details>

HTML
    }

    # 英雄名を持つ部門（英雄総力）はプレイヤーの次に「英雄」列を出す
    my $has_hero = grep { defined $_->{hero_name} && $_->{hero_name} ne '' } @$rows;

    for my $r (@$rows) {
        my $av = img_tag($r->{avatar_url});
        my $hero = $has_hero ? qq{<td class="who name-cell">@{[hero_cell($r)]}</td>} : '';
        $body .= sprintf(
            qq{%s        <tr%s><td class="rk">%s</td><td class="num">%s</td><td class="who"><span class="al-tag">%s</span></td><td class="who name-cell">%s%s</td>%s</tr>\n},
            $pad, toprow($r->{rank}), medal($r->{rank}), fmt($r->{score}),
            val($r->{alliance_abbr}), $av, val($r->{nick_name}), $hero
        );
    }
    my $hero_th = $has_hero ? '<th class="name-cell">英雄</th>' : '';
    return <<"HTML";
$pad<details class="acc">
$pad  <summary>$meta->{icon} $meta->{label}</summary>
$pad  <div class="acc-body">
$pad    <div class="table-wrap">
$pad      <table class="rank-table">
$pad        <thead>
$pad          <tr><th>順位</th><th>$meta->{unit}</th><th>同盟</th><th class="name-cell">プレイヤー</th>$hero_th</tr>
$pad        </thead>
$pad        <tbody>
$body$pad        </tbody>
$pad      </table>
$pad    </div>
$pad  </div>
$pad</details>

HTML
}

# ---------- 最新データの取得 ----------
print "王国情報を取得中（kid=$kid）...\n";
my $k = api("/kingdoms/$kid")->{kingdom};

my $captured;
my %latest;
for my $b (@BOARDS) {
    print "ランキング取得中: $b->{label}...\n";
    my $board = api("/kingdoms/$kid/ranks?board=$b->{key}&limit=10")->{boards}[0];
    $b->{kind} = $board->{kind} || 'player';
    $latest{ $b->{key} } = $board->{rows} || [];
    $captured //= $board->{captured_at};
}

# ---------- 初期版（スナップショット）の読み込み／保存 ----------
my $snapshot = {
    captured_at => $captured,
    kind        => { map { $_->{key} => $_->{kind} } @BOARDS },
    boards      => \%latest,
};

my $baseline;
if (-f $BASELINE && !$reset) {
    # decode_json は「UTF-8のバイト列」を受け取るので、エンコード層を付けずに読む
    open(my $bf, '<:raw', $BASELINE) or die "初期版が読めません: $BASELINE\n";
    local $/; $baseline = decode_json(<$bf>); close $bf;
    print "初期版を読み込みました（" . when($baseline->{captured_at}) . " 時点）\n";
} else {
    make_path('data') unless -d 'data';
    open(my $bf, '>:encoding(UTF-8)', $BASELINE) or die "初期版を書き込めません: $BASELINE\n";
    print $bf JSON::PP->new->canonical->pretty->encode($snapshot);
    close $bf;
    $baseline = $snapshot;
    print(($reset ? "初期版を取り直しました" : "初期版を新規作成しました") . "（" . when($captured) . " 時点）\n");
}

# ---------- ランキングHTML ----------
my $ranks_html = '';
$ranks_html .= render_board($_, $latest{ $_->{key} }, 6) for @BOARDS;

my $base_html = '';
for my $b (@BOARDS) {
    my $meta = { %$b, kind => $baseline->{kind}{ $b->{key} } // $b->{kind} };
    $base_html .= render_board($meta, $baseline->{boards}{ $b->{key} } // [], 10);
}
my $base_when = when($baseline->{captured_at});

# ---------- サーバー概要（自軍との比較） ----------
print "自軍サーバー（kid=$OUR_KID）を取得中...\n";
my $us = api("/kingdoms/$OUR_KID")->{kingdom};

sub rate {
    my ($kk) = @_;
    return '—' unless $kk->{player_count};
    return sprintf('%.0f%%', 100 * ($kk->{active_7d} // 0) / $kk->{player_count});
}

my @rows = (
    [ '👥 プレイヤー数', fmt($k->{player_count}).'人',  fmt($us->{player_count}).'人',
      $k->{player_count}, $us->{player_count}, 1 ],
    [ '🔥 アクティブ(7日)', fmt($k->{active_7d}).'人（'.rate($k).'）', fmt($us->{active_7d}).'人（'.rate($us).'）',
      $k->{active_7d}, $us->{active_7d}, 1 ],
    [ '🏰 同盟数', fmt($k->{alliance_count}), fmt($us->{alliance_count}), undef, undef, 0 ],
    [ '⚔️ サーバー総戦力', fmt($k->{power}), fmt($us->{power}), $k->{power}, $us->{power}, 1 ],
    [ '📊 平均戦力', fmt($k->{avg_power}), fmt($us->{avg_power}), $k->{avg_power}, $us->{avg_power}, 1 ],
    [ '🗺️ 秘境の試練', fmt($k->{mystic_trial}), fmt($us->{mystic_trial}), $k->{mystic_trial}, $us->{mystic_trial}, 1 ],
    [ '📈 7日の伸び', fmt($k->{power_gain_7d}), fmt($us->{power_gain_7d}), $k->{power_gain_7d}, $us->{power_gain_7d}, 1 ],
    # 順位は小さい方が上位なので、比較用の数値を入れ替えて渡す
    [ '🏅 戦力ランク', '全'.fmt($k->{power_rank}).'位', '全'.fmt($us->{power_rank}).'位',
      $us->{power_rank}, $k->{power_rank}, 1 ],
    [ '🎂 開設日', esc($k->{opened_on}).'<br><span class="sub">'.fmt($k->{age_days}).'日目</span>',
                   esc($us->{opened_on}).'<br><span class="sub">'.fmt($us->{age_days}).'日目</span>', undef, undef, 0 ],
);

my $stats_html = '';
for my $r (@rows) {
    my ($label, $ev, $uv, $en, $un, $cmp) = @$r;
    my ($ec, $uc) = ('', '');
    if ($cmp && defined $en && defined $un) {
        if    ($en > $un) { $ec = ' class="win"' }
        elsif ($un > $en) { $uc = ' class="win"' }
    }
    $stats_html .= qq{                <tr><th>$label</th><td$ec>$ev</td><td$uc>$uv</td></tr>\n};
}

# API側で名前が未登録（null）の場合は「○○サーバー」で代替する
my $kname   = (defined $k->{name}  && $k->{name}  ne '') ? esc($k->{name})  : "${kid}サーバー";
my $us_name = (defined $us->{name} && $us->{name} ne '') ? esc($us->{name}) : "${OUR_KID}サーバー";
my $term_html = $term ? qq{<strong>対戦期間：$term</strong><br>} : '';
my $latest_when = when($captured);

# ---------- ページ全体 ----------
my $html = <<"PAGE";
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta name="robots" content="noindex, nofollow">
  <title>$kname（$kid）｜最強王国 敵鯖情報｜CGY 攻略Wiki</title>
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
    <p class="crumb"><a href="event-kingdom.html">← 最強王国 敵鯖情報へ</a></p>

    <section class="hero">
      <h1>🏰 $kname <span class="kid">#$kid</span></h1>
      <p>$term_html
         各項目は見出しをタップで開閉できます。🐾</p>
    </section>

    <section class="card">
      <h2>📋 サーバー概要（自軍との比較）</h2>
      <div class="table-wrap">
        <table class="vs-table">
          <thead>
            <tr>
              <th></th>
              <th class="enemy">$kname<span class="sub">#$kid</span></th>
              <th class="ours">$us_name<span class="sub">#$OUR_KID ぼくら</span></th>
            </tr>
          </thead>
          <tbody>
$stats_html          </tbody>
        </table>
      </div>
      <p class="mini-note">※ 色が付いている方が優勢です。データ取得：$latest_when 時点（MightPulse API）</p>
    </section>

    <section class="cat">
      <h2 class="cat-title">📊 ランキング TOP10</h2>
      <p class="cat-lead">各部門の上位10名／10同盟（最新版）です。開戦時のデータは一番下の「初期版」に格納しています。</p>

$ranks_html      <details class="acc">
        <summary>📁 初期版（$base_when 時点）</summary>
        <div class="acc-body">
          <p class="mini-note">開戦時点のランキングです。最新版との比較用に残しています。</p>

$base_html        </div>
      </details>
    </section>
  </main>

  <footer class="site-footer">
    <p class="paws">🐾 🐾 🐾</p>
    <p>CGY - CritterGangYard 同盟メンバー専用サイト<br>
       ※このサイトは限定公開です。URLの共有はメンバー内のみでお願いします。</p>
  </footer>
</body>
</html>
PAGE

open(my $fh, '>:encoding(UTF-8)', $out) or die "書き込めません: $out\n";
print $fh $html;
close $fh;

print "\n✅ 生成しました: $out\n";
print "   サーバー : $kname (#$kid)\n";
print "   最新版   : $latest_when 時点\n";
print "   初期版   : $base_when 時点（$BASELINE）\n";
