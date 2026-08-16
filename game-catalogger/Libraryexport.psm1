# =====================================================================
#  Library Inventory Export  -  Playnite script extension
#  Version: 1.6.1
#
#  Adds two items under Playnite's Extensions menu:
#    1. Export Library Inventory (CSV + JSON)  - full tabular export
#    2. Export Library Gallery (HTML)          - browsable cover-art page
#
#  Uses only the supported Playnite scripting API ($PlayniteApi); it
#  never touches the underlying database files directly.
#
#  Changelog:
#    1.6.1 - Details view: the side panel now updates on row hover (like
#            g-export), not only on click. Clicking still works.
#    1.6.0 - Added a fourth export: "Details view" - a filterable,
#            sortable data grid (thumbnail, title, store, category
#            icons, played, last played as relative time, star rating)
#            with a cover + description side panel, matching Playnite's
#            own Details view. Stores shown as coloured labels rather
#            than trademarked logos.
#    1.5.0 - Added a third export: "g-export style" - a minimal, dense
#            cover wall with a one-line header, a "show N without
#            activity" toggle (unplayed games hidden by default) and
#            co-op / PvP overlays, styled to match g-export's approach.
#    1.4.0 - Gallery is now metadata-rich: cards show score / year /
#            completion / favourite, and clicking a card opens a detail
#            panel with playtime, all scores, genres, features, tags,
#            developers, publishers, series, platforms, age rating,
#            description and every link. Added score & release-year
#            sorts and a "Played only" filter.
#    1.3.1 - Fix: gallery failed with a null-method error because
#            Playnite does not expose top-level module variables to
#            invoked functions; template now returned by a function.
#    1.3.0 - Cards carry Play (playnite:// launch) and Store buttons.
#    1.2.0 - Cards link to each game's store page; link-coverage footer.
#    1.1.0 - Added HTML gallery export (cover wall, search, filter, sort).
#    1.0.0 - Initial CSV + JSON inventory export.
# =====================================================================

# --- Menu hook -------------------------------------------------------
function GetMainMenuItems
{
    param($getMainMenuItemsArgs)

    $items = @()

    $csv = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $csv.Description  = "Export Library Inventory (CSV + JSON)"
    $csv.FunctionName = "Invoke-LibraryInventoryExport"
    $csv.MenuSection  = "@"
    $items += $csv

    $html = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $html.Description  = "Export Library Gallery (HTML)"
    $html.FunctionName = "Invoke-LibraryGalleryExport"
    $html.MenuSection  = "@"
    $items += $html

    $gx = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $gx.Description  = "Export Library Gallery (g-export style)"
    $gx.FunctionName = "Invoke-LibraryGexportStyleExport"
    $gx.MenuSection  = "@"
    $items += $gx

    $dv = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $dv.Description  = "Export Library (Details view)"
    $dv.FunctionName = "Invoke-LibraryDetailsViewExport"
    $dv.MenuSection  = "@"
    $items += $dv

    return $items
}

# --- Shared helpers --------------------------------------------------

function Convert-ToDisplayDate
{
    param($value)
    if ($null -eq $value) { return "" }
    $dateProp = $value.PSObject.Properties['Date']
    if ($dateProp -and $null -ne $dateProp.Value) {
        return ([datetime]$dateProp.Value).ToString('yyyy-MM-dd')
    }
    try   { return ([datetime]$value).ToString('yyyy-MM-dd') }
    catch { return [string]$value }
}

function Join-NamedList
{
    param($collection)
    if ($null -eq $collection) { return "" }
    $names = foreach ($entry in $collection) {
        if ($null -ne $entry -and $entry.PSObject.Properties['Name']) { $entry.Name }
    }
    return ($names -join "; ")
}

# Returns an array of Name values from a collection of named objects.
function Get-NameArray
{
    param($collection)
    $out = @()
    if ($null -ne $collection) {
        foreach ($e in $collection) {
            if ($null -ne $e -and $e.PSObject.Properties['Name']) { $out += $e.Name }
        }
    }
    return $out
}

function Escape-Html
{
    param($s)
    if ($null -eq $s) { return "" }
    return [System.Security.SecurityElement]::Escape([string]$s)
}

# HTML -> trimmed plain text (for embedding descriptions safely in JSON).
function ConvertTo-PlainText
{
    param($s, $max = 800)
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $t = [regex]::Replace([string]$s, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max) + [char]0x2026 }
    return $t
}

function Get-StoreColor
{
    param($store)
    $map = @{
        'Steam'           = '#66c0f4'
        'GOG'             = '#a970ff'
        'Epic'            = '#dcdcdc'
        'Epic Games'      = '#dcdcdc'
        'EA app'          = '#ff5c5c'
        'Origin'          = '#ff5c5c'
        'Xbox'            = '#5bc236'
        'Battle.net'      = '#3aa0ff'
        'Ubisoft Connect' = '#3d7bff'
        'Amazon Games'    = '#ffb12e'
        'itch.io'         = '#fa5c5c'
        'Humble'          = '#cc2929'
        'Rockstar Games'  = '#f5a623'
        'None'            = '#7a8699'
    }
    if ($map.ContainsKey($store)) { return $map[$store] }
    $h = 0
    foreach ($ch in ([string]$store).ToCharArray()) { $h = ($h * 31 + [int]$ch) % 360 }
    return "hsl($h, 42%, 55%)"
}

function Get-StoreUrl
{
    param($game, $store)
    if ($game.Links) {
        foreach ($lnk in $game.Links) {
            if ($null -eq $lnk -or [string]::IsNullOrEmpty($lnk.Url)) { continue }
            $n = [string]$lnk.Name
            if ($n -match '(?i)store|steam|gog|epic|xbox|ubisoft|origin|\bea\b|battle|amazon|itch') {
                return $lnk.Url
            }
        }
    }
    if ($store -eq 'Steam' -and $game.GameId -match '^\d+$') {
        return "https://store.steampowered.com/app/$($game.GameId)/"
    }
    return ''
}

# --- HTML shell (served from a function; see 1.3.1 note) -------------
function Get-GalleryHtmlShell
{
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Game Library</title>
<style>
:root{
  --bg:#12151b; --bg2:#0d1014; --surface:#1b1f28; --surface2:#232833;
  --line:#2b3340; --text:#e8ebf1; --muted:#98a2b3; --accent:#4cc2d6; --radius:12px;
}
*{box-sizing:border-box}
body{margin:0; color:var(--text); background:linear-gradient(180deg,var(--bg),var(--bg2)); background-attachment:fixed; font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; -webkit-font-smoothing:antialiased}
.topbar{position:sticky; top:0; z-index:10; padding:18px 22px 14px; background:rgba(14,17,22,.86); backdrop-filter:blur(10px); border-bottom:1px solid var(--line)}
.head-row{display:flex; align-items:flex-end; justify-content:space-between; gap:20px; flex-wrap:wrap}
.eyebrow{display:block; font-size:11px; letter-spacing:.18em; text-transform:uppercase; color:var(--muted); margin-bottom:2px}
.brand h1{margin:0; font-size:26px; font-weight:650; letter-spacing:-.01em}
.stats{display:flex; gap:22px}
.stat{display:flex; flex-direction:column; align-items:flex-end}
.stat .num{font-family:ui-monospace,"Cascadia Code",Consolas,monospace; font-size:20px; font-weight:600; line-height:1}
.stat .lbl{font-size:10px; letter-spacing:.14em; text-transform:uppercase; color:var(--muted); margin-top:3px}
.controls{display:flex; gap:10px; margin-top:14px; flex-wrap:wrap; align-items:center}
#search{flex:1 1 240px; min-width:180px; padding:9px 12px; border-radius:9px; background:var(--surface); border:1px solid var(--line); color:var(--text); font-size:14px}
#search:focus{outline:none; border-color:var(--accent); box-shadow:0 0 0 3px rgba(76,194,214,.15)}
#sort{padding:9px 10px; border-radius:9px; background:var(--surface); border:1px solid var(--line); color:var(--text); font-size:13px}
.switch{display:flex; align-items:center; gap:7px; font-size:13px; color:var(--muted); user-select:none; cursor:pointer}
.switch input{accent-color:var(--accent)}
.chips{display:flex; gap:8px; margin-top:12px; flex-wrap:wrap}
.chip{display:inline-flex; align-items:center; gap:7px; padding:5px 11px; border-radius:999px; background:var(--surface); border:1px solid var(--line); color:var(--text); font-size:12.5px; cursor:pointer; transition:border-color .15s, background .15s}
.chip:hover{border-color:var(--c)}
.chip.active{background:color-mix(in srgb, var(--c) 18%, var(--surface)); border-color:var(--c)}
.chip-dot{width:9px; height:9px; border-radius:50%; background:var(--c)}
.chip-n{font-family:ui-monospace,Consolas,monospace; font-size:11px; color:var(--muted)}
.grid{display:grid; gap:16px; padding:22px; grid-template-columns:repeat(auto-fill, minmax(158px, 1fr))}
.card{background:var(--surface); border:1px solid var(--line); border-top:3px solid var(--c); border-radius:var(--radius); overflow:hidden; display:flex; flex-direction:column; cursor:pointer; transition:transform .16s ease, box-shadow .16s ease}
.card:hover{transform:translateY(-3px); box-shadow:0 10px 26px rgba(0,0,0,.4)}
.media{position:relative; aspect-ratio:3/4; background:var(--surface2)}
.cover{width:100%; height:100%; object-fit:cover; display:block}
.cover.ph{display:flex; align-items:center; justify-content:center; font-size:34px; font-weight:700; color:var(--muted); background:linear-gradient(135deg,var(--surface2),var(--surface))}
.badge{position:absolute; top:8px; left:8px; padding:3px 8px; border-radius:6px; font-size:10.5px; font-weight:600; color:#0c0f14; letter-spacing:.02em; box-shadow:0 2px 6px rgba(0,0,0,.35)}
.score{position:absolute; top:8px; right:8px; min-width:24px; height:22px; padding:0 6px; display:flex; align-items:center; justify-content:center; border-radius:6px; background:rgba(12,15,20,.72); color:#eef1f6; font-size:11px; font-weight:700; font-family:ui-monospace,Consolas,monospace; box-shadow:0 2px 6px rgba(0,0,0,.35)}
.info{padding:10px 11px 12px; display:flex; flex-direction:column; gap:6px; flex:1}
.title{margin:0; font-size:13.5px; font-weight:560; line-height:1.25; overflow:hidden; text-overflow:ellipsis; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical}
.subline{font-size:11px; color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap}
.meta{display:flex; align-items:center; justify-content:space-between; margin-top:auto; font-size:11.5px; color:var(--muted)}
.pt{font-family:ui-monospace,Consolas,monospace}
.inst{display:inline-flex; align-items:center; gap:5px}
.dot{width:8px; height:8px; border-radius:50%; border:1.5px solid var(--muted); box-sizing:border-box}
.dot.on{background:#3fbf58; border-color:#3fbf58}
.comp{align-self:flex-start; font-size:10.5px; padding:2px 7px; border-radius:999px; background:var(--surface2); border:1px solid var(--line); color:var(--muted)}
.actions{display:flex; gap:6px; margin-top:4px}
.act{flex:1; display:inline-flex; align-items:center; justify-content:center; gap:5px; padding:6px 8px; border-radius:8px; font-size:11.5px; font-weight:560; text-decoration:none; border:1px solid var(--line); color:var(--text); background:var(--surface2); transition:background .14s, border-color .14s}
.act:hover{border-color:var(--accent)}
.act:focus-visible{outline:2px solid var(--accent); outline-offset:2px}
.act.play{background:color-mix(in srgb, var(--accent) 16%, var(--surface2)); border-color:color-mix(in srgb, var(--accent) 42%, var(--line))}
.act.play:hover{background:color-mix(in srgb, var(--accent) 26%, var(--surface2))}
.empty{text-align:center; color:var(--muted); padding:60px 20px; font-size:15px}
.foot{text-align:center; color:var(--muted); font-size:12px; padding:18px 20px 40px; border-top:1px solid var(--line)}
.modal{position:fixed; inset:0; z-index:100; background:rgba(6,8,11,.72); backdrop-filter:blur(4px); display:flex; align-items:flex-start; justify-content:center; padding:40px 16px; overflow:auto}
.modal[hidden]{display:none}
.modal-inner{position:relative; width:100%; max-width:720px; background:var(--surface); border:1px solid var(--line); border-radius:16px; padding:22px; box-shadow:0 30px 80px rgba(0,0,0,.6)}
.m-close{position:absolute; top:10px; right:14px; background:none; border:none; color:var(--muted); font-size:26px; line-height:1; cursor:pointer}
.m-close:hover{color:var(--text)}
.m-head{display:flex; gap:18px; margin-bottom:14px}
.m-cover{width:132px; flex:0 0 132px; aspect-ratio:3/4; object-fit:cover; border-radius:10px; background:var(--surface2)}
.m-cover.ph{display:flex; align-items:center; justify-content:center; font-size:38px; font-weight:700; color:var(--muted)}
.m-meta{min-width:0}
.m-meta h2{margin:0 0 8px; font-size:22px; line-height:1.15}
.m-sub{display:flex; align-items:center; gap:10px; flex-wrap:wrap; margin-bottom:12px; color:var(--muted); font-size:12.5px}
.m-sub .badge{position:static}
.m-score{font-family:ui-monospace,Consolas,monospace}
.m-actions{max-width:280px}
.m-grid{display:grid; grid-template-columns:repeat(2,1fr); gap:0 22px; margin:4px 0 8px}
.kv{display:flex; justify-content:space-between; gap:12px; padding:6px 0; border-bottom:1px solid var(--line); font-size:12.5px}
.kv .k{color:var(--muted); white-space:nowrap}
.kv .v{text-align:right; color:var(--text)}
.m-sec{margin-top:16px}
.m-sec h4{margin:0 0 8px; font-size:11px; letter-spacing:.14em; text-transform:uppercase; color:var(--muted)}
.badges{display:flex; flex-wrap:wrap; gap:6px}
.tag{font-size:11.5px; padding:3px 9px; border-radius:999px; background:var(--surface2); border:1px solid var(--line); color:var(--text); text-decoration:none}
.tag.feat{border-color:color-mix(in srgb, var(--accent) 40%, var(--line))}
.tag.lnk:hover{border-color:var(--accent)}
.m-desc{font-size:13px; line-height:1.55; color:#c8cdd6; margin:0}
@media (max-width:520px){
  .grid{grid-template-columns:repeat(auto-fill, minmax(130px,1fr)); gap:12px; padding:14px}
  .stats{gap:14px}
  .brand h1{font-size:22px}
  .m-grid{grid-template-columns:1fr}
  .m-head{flex-direction:column}
  .m-cover{width:110px}
}
@media (prefers-reduced-motion:reduce){ *{transition:none !important} }
</style>
</head>
<body>
<header class="topbar">
  <div class="head-row">
    <div class="brand">
      <span class="eyebrow">Playnite inventory</span>
      <h1>Game Library</h1>
    </div>
    <div class="stats">
      <div class="stat"><span class="num" id="vcount">{{TOTAL}}</span><span class="lbl">shown</span></div>
      <div class="stat"><span class="num">{{TOTAL}}</span><span class="lbl">games</span></div>
      <div class="stat"><span class="num">{{INSTALLED}}</span><span class="lbl">installed</span></div>
      <div class="stat"><span class="num">{{STORES}}</span><span class="lbl">stores</span></div>
    </div>
  </div>
  <div class="controls">
    <input id="search" type="search" placeholder="Search games..." autocomplete="off">
    <select id="sort" aria-label="Sort order">
      <option value="name">Sort: Name</option>
      <option value="playtime">Sort: Most played</option>
      <option value="recent">Sort: Recently played</option>
      <option value="score">Sort: Highest score</option>
      <option value="year">Sort: Newest release</option>
    </select>
    <label class="switch"><input id="inst" type="checkbox"> Installed only</label>
    <label class="switch"><input id="played" type="checkbox"> Played only</label>
  </div>
  <div class="chips">{{CHIPS}}</div>
</header>
<main id="grid" class="grid">{{CARDS}}</main>
<p id="empty" class="empty" hidden>No games match your filters.</p>
<footer class="foot">Generated {{GENERATED}} from Playnite &middot; {{TOTAL}} games &middot; {{LINKED}} with store links</footer>

<div id="modal" class="modal" hidden>
  <div class="modal-inner">
    <button class="m-close" aria-label="Close">&times;</button>
    <div id="modal-body"></div>
  </div>
</div>

<script id="gamedata" type="application/json">{{DATA}}</script>
<script>
(function(){
  var grid = document.getElementById('grid');
  var cards = Array.prototype.slice.call(grid.querySelectorAll('.card'));
  var search = document.getElementById('search');
  var chips = Array.prototype.slice.call(document.querySelectorAll('.chip'));
  var instToggle = document.getElementById('inst');
  var playedToggle = document.getElementById('played');
  var sortSel = document.getElementById('sort');
  var countEl = document.getElementById('vcount');
  var emptyEl = document.getElementById('empty');
  var active = {};
  var DATA = JSON.parse(document.getElementById('gamedata').textContent || '[]');
  var modal = document.getElementById('modal');
  var mbody = document.getElementById('modal-body');

  function apply(){
    var q = (search.value || '').trim().toLowerCase();
    var anyStore = Object.keys(active).length > 0;
    var instOnly = instToggle.checked;
    var playedOnly = playedToggle.checked;
    var visible = 0;
    cards.forEach(function(c){
      var okName = !q || c.getAttribute('data-name').indexOf(q) !== -1;
      var okStore = !anyStore || active[c.getAttribute('data-store')];
      var okInst = !instOnly || c.getAttribute('data-installed') === '1';
      var okPlayed = !playedOnly || parseFloat(c.getAttribute('data-playtime')) > 0;
      var show = okName && okStore && okInst && okPlayed;
      c.style.display = show ? '' : 'none';
      if (show) visible++;
    });
    countEl.textContent = visible;
    emptyEl.hidden = visible !== 0;
  }

  function sortCards(){
    var mode = sortSel.value;
    cards.slice().sort(function(a,b){
      if (mode === 'playtime') return parseFloat(b.getAttribute('data-playtime')) - parseFloat(a.getAttribute('data-playtime'));
      if (mode === 'recent') return (b.getAttribute('data-last') || '').localeCompare(a.getAttribute('data-last') || '');
      if (mode === 'score') return ((parseFloat(b.getAttribute('data-score'))||-1) - (parseFloat(a.getAttribute('data-score'))||-1));
      if (mode === 'year') return ((parseInt(b.getAttribute('data-year'),10)||0) - (parseInt(a.getAttribute('data-year'),10)||0));
      return a.getAttribute('data-name').localeCompare(b.getAttribute('data-name'));
    }).forEach(function(c){ grid.appendChild(c); });
  }

  function esc(s){ var d=document.createElement('div'); d.textContent = (s==null?'':String(s)); return d.innerHTML; }
  function chipsHtml(arr, cls){ if(!arr||!arr.length) return ''; return '<div class="badges">'+arr.map(function(x){return '<span class="'+(cls||'tag')+'">'+esc(x)+'</span>';}).join('')+'</div>'; }
  function row(label,val){ if(val==null||val==='') return ''; return '<div class="kv"><span class="k">'+esc(label)+'</span><span class="v">'+esc(val)+'</span></div>'; }

  function openModal(i){
    var g = DATA[i]; if(!g) return;
    var cov = g.cover ? '<img class="m-cover" src="'+esc(g.cover)+'" alt="">'
                      : '<div class="m-cover ph">'+esc((g.name||'?').slice(0,2).toUpperCase())+'</div>';
    var scores = [];
    if(g.community!=null) scores.push('Community '+g.community);
    if(g.critic!=null) scores.push('Critic '+g.critic);
    if(g.user!=null) scores.push('You '+g.user);
    var acts = '';
    if(g.installed && g.playUri) acts += '<a class="act play" href="'+esc(g.playUri)+'">&#9654; Play</a>';
    if(g.storeUrl) acts += '<a class="act store" href="'+esc(g.storeUrl)+'" target="_blank" rel="noopener noreferrer">Store &#8599;</a>';
    var links = '';
    if(g.links && g.links.length){ links = '<div class="m-sec"><h4>Links</h4><div class="badges">'+g.links.map(function(l){return '<a class="tag lnk" href="'+esc(l.url)+'" target="_blank" rel="noopener noreferrer">'+esc(l.name||l.url)+' &#8599;</a>';}).join('')+'</div></div>'; }

    mbody.innerHTML =
      '<div class="m-head">'+cov+
        '<div class="m-meta"><h2>'+(g.favorite?'&#9733; ':'')+esc(g.name)+'</h2>'+
        '<div class="m-sub"><span class="badge" style="background:'+esc(g.color)+'">'+esc(g.store)+'</span>'+
          (g.year?'<span>'+esc(g.year)+'</span>':'')+
          (scores.length?'<span class="m-score">'+esc(scores.join(' \u00b7 '))+'</span>':'')+'</div>'+
        (acts?'<div class="actions m-actions">'+acts+'</div>':'')+
        '</div></div>'+
      '<div class="m-grid">'+
        row('Playtime', g.playtime? g.playtime+' h':'\u2014')+
        row('Status', g.completion)+
        row('Installed', g.installed?'Yes':'No')+
        row('Last played', g.lastPlayed)+
        row('Added', g.added)+
        row('Released', g.released)+
        row('Platforms', (g.platforms||[]).join(', '))+
        row('Developers', (g.developers||[]).join(', '))+
        row('Publishers', (g.publishers||[]).join(', '))+
        row('Series', g.series)+
        row('Version', g.version)+
        row('Age rating', (g.ageRatings||[]).join(', '))+
      '</div>'+
      (g.genres&&g.genres.length?'<div class="m-sec"><h4>Genres</h4>'+chipsHtml(g.genres,'tag')+'</div>':'')+
      (g.features&&g.features.length?'<div class="m-sec"><h4>Features</h4>'+chipsHtml(g.features,'tag feat')+'</div>':'')+
      (g.tags&&g.tags.length?'<div class="m-sec"><h4>Tags</h4>'+chipsHtml(g.tags,'tag')+'</div>':'')+
      (g.description?'<div class="m-sec"><h4>Description</h4><p class="m-desc">'+esc(g.description)+'</p></div>':'')+
      links;

    modal.hidden = false;
    document.body.style.overflow = 'hidden';
  }
  function closeModal(){ modal.hidden = true; document.body.style.overflow = ''; }

  search.addEventListener('input', apply);
  instToggle.addEventListener('change', apply);
  playedToggle.addEventListener('change', apply);
  sortSel.addEventListener('change', sortCards);
  chips.forEach(function(ch){
    ch.addEventListener('click', function(){
      var s = ch.getAttribute('data-store');
      if (active[s]) { delete active[s]; ch.classList.remove('active'); }
      else { active[s] = true; ch.classList.add('active'); }
      apply();
    });
  });
  cards.forEach(function(c){
    c.addEventListener('click', function(e){
      if (e.target.closest('.actions')) return;   // let Play / Store links work
      openModal(parseInt(c.getAttribute('data-idx'), 10));
    });
  });
  modal.addEventListener('click', function(e){ if (e.target === modal || e.target.classList.contains('m-close')) closeModal(); });
  document.addEventListener('keydown', function(e){ if (e.key === 'Escape') closeModal(); });

  apply();
})();
</script>
</body>
</html>
'@
}

# --- CSV + JSON export ----------------------------------------------
function Invoke-LibraryInventoryExport
{
    param($scriptMainMenuItemActionArgs)

    $exportRoot    = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Playnite Exports'
    $includeHidden = $true

    try
    {
        if (-not (Test-Path -LiteralPath $exportRoot)) {
            New-Item -ItemType Directory -Path $exportRoot -Force | Out-Null
        }

        $stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $csvPath  = Join-Path $exportRoot "playnite-library_$stamp.csv"
        $jsonPath = Join-Path $exportRoot "playnite-library_$stamp.json"

        $rows = New-Object System.Collections.Generic.List[object]

        foreach ($game in $PlayniteApi.Database.Games)
        {
            if (-not $includeHidden -and $game.Hidden) { continue }

            $store         = if ($null -ne $game.Source) { $game.Source.Name } else { "None" }
            $playtimeHours = if ($game.Playtime) { [math]::Round($game.Playtime / 3600, 2) } else { 0 }
            $lastPlayed    = if ($game.LastActivity) { ([datetime]$game.LastActivity).ToString('yyyy-MM-dd') } else { "" }
            $dateAdded     = if ($game.Added)        { ([datetime]$game.Added).ToString('yyyy-MM-dd') }        else { "" }
            $completion    = if ($null -ne $game.CompletionStatus) { $game.CompletionStatus.Name } else { "" }

            $rows.Add([pscustomobject][ordered]@{
                Name             = $game.Name
                Store            = $store
                Platforms        = Join-NamedList $game.Platforms
                Installed        = [bool]$game.IsInstalled
                InstallDirectory = $game.InstallDirectory
                PlaytimeHours    = $playtimeHours
                LastPlayed       = $lastPlayed
                DateAdded        = $dateAdded
                ReleaseDate      = Convert-ToDisplayDate $game.ReleaseDate
                CompletionStatus = $completion
                CommunityScore   = $game.CommunityScore
                CriticScore      = $game.CriticScore
                UserScore        = $game.UserScore
                Favorite         = [bool]$game.Favorite
                Hidden           = [bool]$game.Hidden
                Genres           = Join-NamedList $game.Genres
                Features         = Join-NamedList $game.Features
                Tags             = Join-NamedList $game.Tags
                Developers       = Join-NamedList $game.Developers
                Publishers       = Join-NamedList $game.Publishers
                Series           = Join-NamedList $game.Series
                StoreGameId      = $game.GameId
                PlayniteId       = $game.Id
            })
        }

        $sorted = $rows | Sort-Object Store, Name
        $sorted | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        $sorted | ConvertTo-Json -Depth 4 | Out-File -LiteralPath $jsonPath -Encoding UTF8

        $storeSummary = ($sorted | Group-Object Store | Sort-Object Count -Descending |
            ForEach-Object { "  {0}: {1}" -f $_.Name, $_.Count }) -join "`n"

        $message = @"
Exported $($rows.Count) games.

By store:
$storeSummary

CSV:  $csvPath
JSON: $jsonPath
"@
        $PlayniteApi.Dialogs.ShowMessage($message, "Library Inventory Export")
    }
    catch
    {
        $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.Message, "Library Inventory Export - Failed")
    }
}

# --- HTML gallery export --------------------------------------------
function Invoke-LibraryGalleryExport
{
    param($scriptMainMenuItemActionArgs)

    # ---- Configuration ----------------------------------------------
    $exportRoot          = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Playnite Exports'
    $includeHidden       = $false   # skip games marked Hidden
    $autoOpen            = $true     # open the page when done
    $includeDescriptions = $true     # set $false to shrink the file on huge libraries
    # -----------------------------------------------------------------

    try
    {
        $stamp     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $outDir    = Join-Path $exportRoot "gallery_$stamp"
        $coversDir = Join-Path $outDir 'covers'
        New-Item -ItemType Directory -Path $coversDir -Force | Out-Null

        $cards          = New-Object System.Collections.Generic.List[string]
        $dataList       = New-Object System.Collections.Generic.List[object]
        $storeCounts    = @{}
        $total          = 0
        $installedCount = 0
        $linkedCount    = 0
        $idx            = 0

        $games = $PlayniteApi.Database.Games | Sort-Object { $_.Source.Name }, Name

        foreach ($game in $games)
        {
            if (-not $includeHidden -and $game.Hidden) { continue }
            $total++

            $store = if ($null -ne $game.Source) { $game.Source.Name } else { 'None' }
            if ($storeCounts.ContainsKey($store)) { $storeCounts[$store]++ } else { $storeCounts[$store] = 1 }

            $installed = 0
            if ($game.IsInstalled) { $installed = 1; $installedCount++ }

            $playHours  = if ($game.Playtime) { [math]::Round($game.Playtime / 3600, 1) } else { 0 }
            $last       = if ($game.LastActivity) { ([datetime]$game.LastActivity).ToString('yyyy-MM-dd') } else { '' }
            $added      = if ($game.Added)        { ([datetime]$game.Added).ToString('yyyy-MM-dd') }        else { '' }
            $completion = if ($null -ne $game.CompletionStatus) { $game.CompletionStatus.Name } else { '' }
            $released   = Convert-ToDisplayDate $game.ReleaseDate
            $year       = if ($released.Length -ge 4) { $released.Substring(0,4) } else { '' }

            $coverRel = ''
            if ($game.CoverImage) {
                $src = $PlayniteApi.Database.GetFullFilePath($game.CoverImage)
                if ($src -and (Test-Path -LiteralPath $src)) {
                    $ext = [System.IO.Path]::GetExtension($src)
                    if ([string]::IsNullOrEmpty($ext)) { $ext = '.jpg' }
                    $destName = "$($game.Id)$ext"
                    try {
                        Copy-Item -LiteralPath $src -Destination (Join-Path $coversDir $destName) -Force
                        $coverRel = "covers/$destName"
                    } catch { $coverRel = '' }
                }
            }

            $url = Get-StoreUrl $game $store
            if ($url) { $linkedCount++ }

            $scoreVal = if ($null -ne $game.CommunityScore) { $game.CommunityScore }
                        elseif ($null -ne $game.CriticScore) { $game.CriticScore }
                        else { '' }

            # --- rich data object for the detail panel -------------------
            $desc = if ($includeDescriptions) { ConvertTo-PlainText $game.Description } else { '' }

            $linkObjs = @()
            if ($game.Links) {
                foreach ($lnk in $game.Links) {
                    if ($lnk -and -not [string]::IsNullOrEmpty($lnk.Url)) {
                        $linkObjs += [ordered]@{ name = [string]$lnk.Name; url = [string]$lnk.Url }
                    }
                }
            }

            $dataList.Add([ordered]@{
                name        = $game.Name
                store       = $store
                color       = Get-StoreColor $store
                cover       = $coverRel
                installed   = [bool]$game.IsInstalled
                playtime    = $playHours
                year        = $year
                released    = $released
                added       = $added
                lastPlayed  = $last
                completion  = $completion
                favorite    = [bool]$game.Favorite
                community   = $game.CommunityScore
                critic      = $game.CriticScore
                user        = $game.UserScore
                genres      = @(Get-NameArray $game.Genres)
                features    = @(Get-NameArray $game.Features)
                tags        = @(Get-NameArray $game.Tags)
                developers  = @(Get-NameArray $game.Developers)
                publishers  = @(Get-NameArray $game.Publishers)
                series      = ((Get-NameArray $game.Series) -join ', ')
                platforms   = @(Get-NameArray $game.Platforms)
                ageRatings  = @(Get-NameArray $game.AgeRatings)
                version     = [string]$game.Version
                description = $desc
                links       = $linkObjs
                playUri     = "playnite://playnite/start/$($game.Id)"
                storeUrl    = $url
            })

            # --- compact card front --------------------------------------
            $color    = Get-StoreColor $store
            $nameEsc  = Escape-Html $game.Name
            $nameAttr = Escape-Html (([string]$game.Name).ToLower())
            $storeEsc = Escape-Html $store

            if ($coverRel) {
                $media = "<img class=""cover"" loading=""lazy"" src=""$coverRel"" alt=""$nameEsc"">"
            } else {
                $rawName = [string]$game.Name
                $init    = Escape-Html ($rawName.Substring(0, [Math]::Min(2, $rawName.Length)).ToUpper())
                $media   = "<div class=""cover ph"">$init</div>"
            }

            $scorePill = if ($scoreVal -ne '') { "<span class=""score"">$scoreVal</span>" } else { "" }
            $favStar   = if ($game.Favorite) { "&#9733; " } else { "" }
            $instHtml  = if ($installed -eq 1) { "<span class=""dot on""></span>Installed" } else { "<span class=""dot""></span>Not installed" }
            $playLabel = if ($playHours -gt 0) { "$playHours h" } else { "&mdash;" }

            $genreArr = @(Get-NameArray $game.Genres)
            $sublineParts = @()
            if ($year) { $sublineParts += $year }
            if ($genreArr.Count -gt 0) { $sublineParts += (Escape-Html $genreArr[0]) }
            $subline  = if ($sublineParts.Count -gt 0) { "<div class=""subline"">" + ($sublineParts -join " &middot; ") + "</div>" } else { "" }
            $compChip = if ($completion) { "<span class=""comp"">" + (Escape-Html $completion) + "</span>" } else { "" }

            $actList = @()
            if ($installed -eq 1) { $actList += "<a class=""act play"" href=""playnite://playnite/start/$($game.Id)"">&#9654; Play</a>" }
            if ($url)             { $actList += "<a class=""act store"" href=""$(Escape-Html $url)"" target=""_blank"" rel=""noopener noreferrer"">Store &#8599;</a>" }
            $actions = if ($actList.Count -gt 0) { "<div class=""actions"">" + ($actList -join "") + "</div>" } else { "" }

            $mediaBlock = "<div class=""media"">$media<span class=""badge"" style=""background:$color"">$storeEsc</span>$scorePill</div>"
            $infoBlock  = "<div class=""info""><h3 class=""title"" title=""$nameEsc"">$favStar$nameEsc</h3>$subline<div class=""meta""><span class=""pt"">$playLabel</span><span class=""inst"">$instHtml</span></div>$compChip$actions</div>"

            $scoreAttr = if ($scoreVal -ne '') { $scoreVal } else { '' }
            $card = "<article class=""card"" data-idx=""$idx"" data-name=""$nameAttr"" data-store=""$storeEsc"" data-installed=""$installed"" data-playtime=""$playHours"" data-last=""$last"" data-score=""$scoreAttr"" data-year=""$year"" style=""--c:$color"">$mediaBlock$infoBlock</article>"
            $cards.Add($card)
            $idx++
        }

        $chipList = New-Object System.Collections.Generic.List[string]
        foreach ($kv in ($storeCounts.GetEnumerator() | Sort-Object Name)) {
            $c    = Get-StoreColor $kv.Key
            $kEsc = Escape-Html $kv.Key
            $chipList.Add("<button class=""chip"" data-store=""$kEsc"" style=""--c:$c""><span class=""chip-dot""></span>$kEsc <span class=""chip-n"">$($kv.Value)</span></button>")
        }

        $storeCount = $storeCounts.Count
        $generated  = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $cardsHtml  = ($cards -join "`n")
        $chipsHtml  = ($chipList -join "`n")

        if ($total -gt 0) {
            $json = ConvertTo-Json -InputObject @($dataList.ToArray()) -Depth 6 -Compress
        } else {
            $json = '[]'
        }
        # Prevent a stray "</..." inside descriptions from closing the <script> tag early.
        $json = $json.Replace('</', '<\/')

        $html = (Get-GalleryHtmlShell).Replace('{{CARDS}}', $cardsHtml).Replace('{{CHIPS}}', $chipsHtml).Replace('{{DATA}}', $json).Replace('{{TOTAL}}', [string]$total).Replace('{{INSTALLED}}', [string]$installedCount).Replace('{{STORES}}', [string]$storeCount).Replace('{{LINKED}}', [string]$linkedCount).Replace('{{GENERATED}}', $generated)

        $indexPath = Join-Path $outDir 'index.html'
        $html | Out-File -LiteralPath $indexPath -Encoding UTF8

        $PlayniteApi.Dialogs.ShowMessage("Gallery exported: $total games across $storeCount stores ($linkedCount with store links).`n`n$indexPath", "Library Gallery Export")
        if ($autoOpen) { try { Start-Process $indexPath } catch {} }
    }
    catch
    {
        $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.Message, "Library Gallery Export - Failed")
    }
}


# --- g-export style shell (minimal cover wall) ----------------------
function Get-GexportHtmlShell
{
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>My Games</title>
<style>
*{box-sizing:border-box}
body{margin:0; background:#101216; color:#e8eaed; font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; -webkit-font-smoothing:antialiased}
header{padding:16px 20px; font-size:14px; color:#aeb4bd; border-bottom:1px solid #262b33; line-height:1.7}
header .count{color:#e8eaed; font-weight:600}
header time{color:#cfd4db}
#toggle{background:none; border:none; color:#5ad1e6; cursor:pointer; font:inherit; padding:0; text-decoration:underline}
#toggle:hover{color:#8fe3f1}
.wall{display:grid; grid-template-columns:repeat(auto-fill,minmax(120px,1fr)); gap:10px; padding:16px 20px}
.tile{position:relative; display:block; aspect-ratio:3/4; border-radius:6px; overflow:hidden; background:#1b1f27; text-decoration:none; color:inherit}
.tile img{width:100%; height:100%; object-fit:cover; display:block}
.tile .ph{width:100%; height:100%; display:flex; align-items:center; justify-content:center; font-size:26px; font-weight:700; color:#6b7280}
.tile .ov{position:absolute; inset:auto 0 0 0; padding:20px 8px 7px; background:linear-gradient(transparent,rgba(6,8,11,.94)); opacity:0; transition:opacity .14s}
.tile:hover .ov{opacity:1}
.tile .nm{display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; font-size:11.5px; font-weight:600; line-height:1.2}
.tile .tg{display:block; color:#aeb4bd; font-size:10px; margin-top:3px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap}
.flags{position:absolute; top:6px; left:6px; display:flex; gap:4px}
.flag{font-size:9px; font-weight:700; letter-spacing:.04em; padding:2px 5px; border-radius:4px; background:rgba(6,8,11,.72)}
.flag.coop{color:#5bd68a}
.flag.pvp{color:#ff7a7a}
body:not(.show-all) .tile.no-activity{display:none}
.foot{padding:14px 20px 40px; color:#6b7280; font-size:12px; border-top:1px solid #262b33}
@media (max-width:520px){ .wall{grid-template-columns:repeat(auto-fill,minmax(96px,1fr)); gap:8px; padding:12px} }
@media (prefers-reduced-motion:reduce){ *{transition:none !important} }
</style>
</head>
<body>
<header>
  <span class="count">{{WITHACT}} games</span> &ndash; game list exported from Playnite using Library Inventory Export &ndash; <time>{{GENERATED}}</time> &ndash; <button id="toggle" data-n="{{NOACT}}">show {{NOACT}} without activity</button>
</header>
<main class="wall">{{TILES}}</main>
<footer class="foot">{{TOTAL}} games total.</footer>
<script>
(function(){
  var t=document.getElementById('toggle');
  if(!t) return;
  t.addEventListener('click',function(){
    document.body.classList.toggle('show-all');
    var on=document.body.classList.contains('show-all');
    t.textContent=(on?'hide ':'show ')+t.getAttribute('data-n')+' without activity';
  });
})();
</script>
</body>
</html>
'@
}

# --- g-export style export ------------------------------------------
function Invoke-LibraryGexportStyleExport
{
    param($scriptMainMenuItemActionArgs)

    # ---- Configuration ----------------------------------------------
    $exportRoot    = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Playnite Exports'
    $includeHidden = $false
    $autoOpen      = $true
    # -----------------------------------------------------------------

    try
    {
        $stamp     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $outDir    = Join-Path $exportRoot "gexport_$stamp"
        $coversDir = Join-Path $outDir 'covers'
        New-Item -ItemType Directory -Path $coversDir -Force | Out-Null

        $tiles        = New-Object System.Collections.Generic.List[string]
        $total        = 0
        $withActivity = 0

        # Most-played first (activity-forward, like g-export).
        $games = $PlayniteApi.Database.Games | Sort-Object { -([double]$_.Playtime) }, Name

        foreach ($game in $games)
        {
            if (-not $includeHidden -and $game.Hidden) { continue }
            $total++

            $playHours = if ($game.Playtime) { [math]::Round($game.Playtime / 3600, 1) } else { 0 }
            $activity  = if ($playHours -gt 0) { 1 } else { 0 }
            if ($activity -eq 1) { $withActivity++ }

            $store = if ($null -ne $game.Source) { $game.Source.Name } else { 'None' }

            $coverRel = ''
            if ($game.CoverImage) {
                $src = $PlayniteApi.Database.GetFullFilePath($game.CoverImage)
                if ($src -and (Test-Path -LiteralPath $src)) {
                    $ext = [System.IO.Path]::GetExtension($src)
                    if ([string]::IsNullOrEmpty($ext)) { $ext = '.jpg' }
                    $destName = "$($game.Id)$ext"
                    try { Copy-Item -LiteralPath $src -Destination (Join-Path $coversDir $destName) -Force; $coverRel = "covers/$destName" } catch { $coverRel = '' }
                }
            }

            $url     = Get-StoreUrl $game $store
            $nameEsc = Escape-Html $game.Name

            if ($coverRel) {
                $img = "<img loading=""lazy"" src=""$coverRel"" alt=""$nameEsc"">"
            } else {
                $rawName = [string]$game.Name
                $init    = Escape-Html ($rawName.Substring(0,[Math]::Min(2,$rawName.Length)).ToUpper())
                $img     = "<div class=""ph"">$init</div>"
            }

            $features = @(Get-NameArray $game.Features)
            $flags = ''
            if ($features -match '(?i)co-?op') { $flags += "<span class=""flag coop"">CO-OP</span>" }
            if ($features -match '(?i)pvp')     { $flags += "<span class=""flag pvp"">PVP</span>" }
            $flagsHtml = if ($flags) { "<div class=""flags"">$flags</div>" } else { "" }

            $tagArr  = @(Get-NameArray $game.Tags)
            $tagLine = if ($tagArr.Count -gt 0) { "<span class=""tg"">" + (Escape-Html (($tagArr | Select-Object -First 2) -join ', ')) + "</span>" } else { "" }

            $ov      = "<div class=""ov""><span class=""nm"">$nameEsc</span>$tagLine</div>"
            $naClass = if ($activity -eq 0) { " no-activity" } else { "" }

            if ($url) {
                $urlEsc = Escape-Html $url
                $tile = "<a class=""tile$naClass"" href=""$urlEsc"" target=""_blank"" rel=""noopener noreferrer"" title=""$nameEsc"" data-activity=""$activity"">$img$flagsHtml$ov</a>"
            } else {
                $tile = "<div class=""tile$naClass"" title=""$nameEsc"" data-activity=""$activity"">$img$flagsHtml$ov</div>"
            }
            $tiles.Add($tile)
        }

        $noActivity = $total - $withActivity
        $generated  = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $tilesHtml  = ($tiles -join "`n")

        $html = (Get-GexportHtmlShell).Replace('{{TILES}}', $tilesHtml).Replace('{{WITHACT}}', [string]$withActivity).Replace('{{NOACT}}', [string]$noActivity).Replace('{{TOTAL}}', [string]$total).Replace('{{GENERATED}}', $generated)

        $indexPath = Join-Path $outDir 'index.html'
        $html | Out-File -LiteralPath $indexPath -Encoding UTF8

        $PlayniteApi.Dialogs.ShowMessage("g-export style gallery: $total games ($withActivity with activity, $noActivity without).`n`n$indexPath", "Library Gallery (g-export style)")
        if ($autoOpen) { try { Start-Process $indexPath } catch {} }
    }
    catch
    {
        $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.Message, "Library Gallery (g-export style) - Failed")
    }
}


# --- Shared rich-record builder (used by Details view) --------------
function New-GameRecord
{
    param($game, $coversDir, [bool]$includeDescriptions = $true)

    $store = if ($null -ne $game.Source) { $game.Source.Name } else { 'None' }

    $coverRel = ''
    if ($game.CoverImage) {
        $src = $PlayniteApi.Database.GetFullFilePath($game.CoverImage)
        if ($src -and (Test-Path -LiteralPath $src)) {
            $ext = [System.IO.Path]::GetExtension($src)
            if ([string]::IsNullOrEmpty($ext)) { $ext = '.jpg' }
            $destName = "$($game.Id)$ext"
            try { Copy-Item -LiteralPath $src -Destination (Join-Path $coversDir $destName) -Force; $coverRel = "covers/$destName" } catch { $coverRel = '' }
        }
    }

    $playHours  = if ($game.Playtime) { [math]::Round($game.Playtime / 3600, 1) } else { 0 }
    $last       = if ($game.LastActivity) { ([datetime]$game.LastActivity).ToString('yyyy-MM-dd') } else { '' }
    $added      = if ($game.Added) { ([datetime]$game.Added).ToString('yyyy-MM-dd') } else { '' }
    $released   = Convert-ToDisplayDate $game.ReleaseDate
    $year       = if ($released.Length -ge 4) { $released.Substring(0,4) } else { '' }
    $completion = if ($null -ne $game.CompletionStatus) { $game.CompletionStatus.Name } else { '' }

    $rating = $null
    if ($null -ne $game.UserScore) { $rating = $game.UserScore }
    elseif ($null -ne $game.CommunityScore) { $rating = $game.CommunityScore }
    elseif ($null -ne $game.CriticScore) { $rating = $game.CriticScore }

    $desc = if ($includeDescriptions) { ConvertTo-PlainText $game.Description } else { '' }

    $linkObjs = @()
    if ($game.Links) {
        foreach ($lnk in $game.Links) {
            if ($lnk -and -not [string]::IsNullOrEmpty($lnk.Url)) { $linkObjs += [ordered]@{ name = [string]$lnk.Name; url = [string]$lnk.Url } }
        }
    }

    return [ordered]@{
        name        = $game.Name
        cover       = $coverRel
        store       = $store
        color       = Get-StoreColor $store
        storeUrl    = Get-StoreUrl $game $store
        playUri     = "playnite://playnite/start/$($game.Id)"
        installed   = [bool]$game.IsInstalled
        playtime    = $playHours
        lastPlayed  = $last
        added       = $added
        released    = $released
        year        = $year
        rating      = $rating
        favorite    = [bool]$game.Favorite
        completion  = $completion
        genres      = @(Get-NameArray $game.Genres)
        features    = @(Get-NameArray $game.Features)
        tags        = @(Get-NameArray $game.Tags)
        developers  = @(Get-NameArray $game.Developers)
        publishers  = @(Get-NameArray $game.Publishers)
        series      = ((Get-NameArray $game.Series) -join ', ')
        platforms   = @(Get-NameArray $game.Platforms)
        version     = [string]$game.Version
        description = $desc
        links       = $linkObjs
    }
}

# --- Details-view shell (data grid + side panel) --------------------
function Get-DetailsViewHtmlShell
{
    return @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Game Library</title>
<style>
:root{--bg:#141414;--panel:#1c1c1c;--rowalt:#181818;--hover:#242424;--sel:#2a2f38;--line:#2a2a2a;--text:#e6e8ea;--muted:#9aa0a6;--star:#e6b625;--accent:#4cc2d6}
*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;-webkit-font-smoothing:antialiased;font-size:13px}
.app{display:flex;height:100vh;overflow:hidden}
.left{flex:1;min-width:0;display:flex;flex-direction:column;border-right:1px solid var(--line)}
.bar{padding:8px 12px;border-bottom:1px solid var(--line);color:var(--muted);font-size:12px;display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
.tablewrap{flex:1;overflow:auto}
table{width:100%;border-collapse:collapse}
thead th{position:sticky;top:0;background:#101010;z-index:2;text-align:left;font-weight:600;color:#cfd3d7;padding:7px 8px;border-bottom:1px solid var(--line);white-space:nowrap;font-size:12px}
thead th[data-sort]{cursor:pointer;user-select:none}
thead th[data-sort]:hover{color:#fff}
.ind{color:var(--accent);font-size:10px;margin-left:3px}
.frow th{position:sticky;top:31px;background:#141414;z-index:2;padding:5px 8px;border-bottom:1px solid var(--line)}
.frow input,.frow select{width:100%;background:#0e0e0e;border:1px solid #333;color:var(--text);border-radius:4px;padding:4px 6px;font-size:12px}
.frow input:focus,.frow select:focus{outline:none;border-color:var(--accent)}
tbody td{padding:4px 8px;border-bottom:1px solid #202020;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
tbody tr{cursor:pointer}
tbody tr:nth-child(even){background:var(--rowalt)}
tbody tr:hover{background:var(--hover)}
tbody tr.sel{background:var(--sel)}
.c-thumb{width:30px;padding:2px 4px 2px 8px}
.c-thumb img,.c-thumb .ph{width:24px;height:24px;border-radius:3px;object-fit:cover;display:block;background:#2a2a2a}
.c-thumb .ph{display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:700;color:#777}
.c-title{max-width:340px;font-weight:500}
.c-plat .store-chip{display:inline-block;padding:1px 7px;border-radius:4px;font-size:10.5px;font-weight:600;color:#0c0f14;background:var(--c,#888)}
.c-cat{color:var(--muted)}
.ci{display:inline-flex;vertical-align:middle;margin-right:5px}
.c-played{text-align:right;font-variant-numeric:tabular-nums;color:#cfd3d7}
.c-last{color:var(--muted)}
.st{color:#3a3a3a}
.st.on{color:var(--star)}
.detail{width:340px;flex:0 0 340px;overflow:auto;background:var(--panel);padding:0 0 30px}
.d-empty{padding:40px 20px;color:var(--muted);text-align:center}
.d-cover{width:100%;display:block;background:#111}
.d-body{padding:16px 18px}
.d-title{margin:0 0 8px;font-size:20px;line-height:1.2}
.d-sub{display:flex;align-items:center;gap:9px;flex-wrap:wrap;color:var(--muted);font-size:12px;margin-bottom:12px}
.d-sub .store-chip{padding:1px 7px;border-radius:4px;font-size:10.5px;font-weight:600;color:#0c0f14}
.d-sub .stars .st{font-size:13px}
.d-actions{display:flex;gap:7px;margin-bottom:14px}
.act{flex:1;display:inline-flex;align-items:center;justify-content:center;gap:5px;padding:7px 8px;border-radius:7px;font-size:12px;font-weight:600;text-decoration:none;border:1px solid #333;color:var(--text);background:#242424}
.act:hover{border-color:var(--accent)}
.act.play{background:color-mix(in srgb,var(--accent) 18%,#242424);border-color:color-mix(in srgb,var(--accent) 45%,#333)}
.d-desc{font-size:12.5px;line-height:1.55;color:#c4c8cc;margin:0 0 14px}
.d-sec{margin-bottom:12px}
.d-sec h4{margin:0 0 6px;font-size:10.5px;letter-spacing:.13em;text-transform:uppercase;color:var(--muted)}
.badges{display:flex;flex-wrap:wrap;gap:5px}
.tag{font-size:11px;padding:2px 8px;border-radius:999px;background:#242424;border:1px solid #333;color:var(--text);text-decoration:none}
.tag.lnk:hover{border-color:var(--accent)}
.kv{display:flex;justify-content:space-between;gap:10px;font-size:12px;padding:4px 0;border-bottom:1px solid #242424}
.kv .k{color:var(--muted)}
@media (max-width:720px){.detail{display:none}.left{border-right:none}}
</style>
</head>
<body>
<div class="app">
  <div class="left">
    <div class="bar"><span id="count">{{TOTAL}}</span><span>Generated {{GENERATED}} from Playnite</span></div>
    <div class="tablewrap">
      <table>
        <thead>
          <tr>
            <th></th>
            <th data-sort="name">Title <span class="ind" data-for="name"></span></th>
            <th>Platforms</th>
            <th>Categories</th>
            <th data-sort="playtime">Played <span class="ind" data-for="playtime"></span></th>
            <th data-sort="lastPlayed">Last Played <span class="ind" data-for="lastPlayed"></span></th>
            <th data-sort="rating">Rating <span class="ind" data-for="rating"></span></th>
          </tr>
          <tr class="frow">
            <th></th>
            <th><input id="f-title" type="search" placeholder="Filter..." autocomplete="off"></th>
            <th><select id="f-store"><option value="">All</option></select></th>
            <th><select id="f-cat"><option value="">All</option><option value="single">Single-player</option><option value="multi">Multiplayer</option><option value="coop">Co-op</option><option value="pvp">PvP</option></select></th>
            <th></th>
            <th></th>
            <th><select id="f-rating"><option value="">All</option><option value="5">5 stars</option><option value="4">4+ stars</option><option value="3">3+ stars</option><option value="2">2+ stars</option><option value="1">1+ stars</option></select></th>
          </tr>
        </thead>
        <tbody id="rows"></tbody>
      </table>
    </div>
  </div>
  <aside class="detail" id="detail"><div class="d-empty">Select a game to see details.</div></aside>
</div>
<script id="data" type="application/json">{{DATA}}</script>
<script>
(function(){
  var DATA = JSON.parse(document.getElementById('data').textContent || '[]');
  DATA.forEach(function(g,i){ g._i=i; });
  var rowsEl=document.getElementById('rows'), detailEl=document.getElementById('detail'), countEl=document.getElementById('count');
  var fTitle=document.getElementById('f-title'), fStore=document.getElementById('f-store'), fCat=document.getElementById('f-cat'), fRating=document.getElementById('f-rating');
  var sortKey='name', sortDir=1, selected=null;

  var IC={
    single:'<svg viewBox="0 0 14 14" width="13" height="13" fill="currentColor"><circle cx="7" cy="4" r="2.6"/><path d="M1.6 13c0-3 2.4-5 5.4-5s5.4 2 5.4 5z"/></svg>',
    multi:'<svg viewBox="0 0 20 14" width="19" height="13" fill="currentColor"><circle cx="6" cy="4" r="2.3"/><path d="M1 13c0-2.7 2.2-4.4 5-4.4s5 1.7 5 4.4z"/><circle cx="14.5" cy="4.6" r="2.1"/><path d="M10 13c0-2.5 2-4 4.5-4s4.5 1.5 4.5 4z"/></svg>',
    coop:'<svg viewBox="0 0 26 14" width="25" height="13" fill="currentColor"><circle cx="5" cy="4" r="2.1"/><path d="M0.6 13c0-2.5 2-4 4.4-4s4.4 1.5 4.4 4z"/><circle cx="13" cy="4.3" r="2"/><path d="M8.8 13c0-2.4 1.9-3.8 4.2-3.8s4.2 1.4 4.2 3.8z"/><circle cx="21" cy="4" r="2.1"/><path d="M16.6 13c0-2.5 2-4 4.4-4s4.4 1.5 4.4 4z"/></svg>',
    pvp:'<svg viewBox="0 0 16 16" width="14" height="14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"><path d="M3 13L11 5"/><path d="M13 13L5 5"/><path d="M10.5 3.5H13V6"/><path d="M5.5 3.5H3V6"/></svg>'
  };
  function esc(s){var d=document.createElement('div');d.textContent=(s==null?'':String(s));return d.innerHTML;}
  function starN(r){ if(r==null||r==='')return -1; var n=Math.round(r/20); return n<0?0:(n>5?5:n); }
  function starsHtml(r){ var n=starN(r); if(n<0)return ''; var s=''; for(var i=0;i<5;i++){s+='<span class="st'+(i<n?' on':'')+'">\u2605</span>';} return s; }
  function catIcons(features){
    if(!features)return ''; var f=features.map(function(x){return String(x).toLowerCase();});
    function has(re){return f.some(function(x){return re.test(x);});}
    var o='';
    if(has(/single/))o+='<span class="ci" title="Single-player">'+IC.single+'</span>';
    if(has(/multiplayer|multi-player/))o+='<span class="ci" title="Multiplayer">'+IC.multi+'</span>';
    if(has(/co-?op/))o+='<span class="ci" title="Co-op">'+IC.coop+'</span>';
    if(has(/pvp|versus/))o+='<span class="ci" title="PvP">'+IC.pvp+'</span>';
    return o;
  }
  function catKey(features){ var s=catIcons(features); return {single:/Single-player/.test(s),multi:/Multiplayer/.test(s),coop:/Co-op/.test(s),pvp:/PvP/.test(s)}; }
  function rel(iso){
    if(!iso)return ''; var d=new Date(iso+'T00:00:00'); if(isNaN(d))return iso;
    var days=Math.floor((Date.now()-d.getTime())/86400000);
    if(days<1)return 'today'; if(days<2)return 'yesterday'; if(days<30)return days+' days ago';
    var m=Math.floor(days/30.44); if(m<12)return m+(m===1?' month ago':' months ago');
    var y=Math.floor(days/365.25); return y+(y===1?' year ago':' years ago');
  }

  // populate store filter
  var storesSeen={};
  DATA.forEach(function(g){ if(g.store && !storesSeen[g.store]){storesSeen[g.store]=1;} });
  Object.keys(storesSeen).sort().forEach(function(s){ var o=document.createElement('option'); o.value=s; o.textContent=s; fStore.appendChild(o); });

  function passes(g){
    var q=(fTitle.value||'').trim().toLowerCase();
    if(q && String(g.name||'').toLowerCase().indexOf(q)===-1) return false;
    if(fStore.value && g.store!==fStore.value) return false;
    if(fCat.value){ var k=catKey(g.features); if(!k[fCat.value]) return false; }
    if(fRating.value){ if(starN(g.rating) < parseInt(fRating.value,10)) return false; }
    return true;
  }
  function cmp(a,b){
    var v;
    if(sortKey==='name') v=String(a.name||'').localeCompare(String(b.name||''));
    else if(sortKey==='playtime') v=(a.playtime||0)-(b.playtime||0);
    else if(sortKey==='lastPlayed') v=String(a.lastPlayed||'').localeCompare(String(b.lastPlayed||''));
    else if(sortKey==='rating') v=(starN(a.rating))-(starN(b.rating));
    return v*sortDir;
  }
  function render(){
    var list=DATA.filter(passes).slice().sort(cmp);
    var html='';
    list.forEach(function(g){
      var thumb=g.cover?'<img loading="lazy" src="'+esc(g.cover)+'">':'<div class="ph">'+esc((g.name||'?').slice(0,2).toUpperCase())+'</div>';
      var chip=g.store?'<span class="store-chip" style="--c:'+esc(g.color)+'">'+esc(g.store)+'</span>':'';
      html+='<tr class="'+(selected===g._i?'sel':'')+'" data-i="'+g._i+'">'+
        '<td class="c-thumb">'+thumb+'</td>'+
        '<td class="c-title" title="'+esc(g.name)+'">'+esc(g.name)+'</td>'+
        '<td class="c-plat">'+chip+'</td>'+
        '<td class="c-cat">'+catIcons(g.features)+'</td>'+
        '<td class="c-played">'+(g.playtime>0?g.playtime+' h':'')+'</td>'+
        '<td class="c-last">'+rel(g.lastPlayed)+'</td>'+
        '<td class="c-rating">'+starsHtml(g.rating)+'</td>'+
      '</tr>';
    });
    rowsEl.innerHTML=html;
    countEl.textContent=list.length+(list.length===1?' game':' games');
    document.querySelectorAll('.ind').forEach(function(e){ e.textContent = (e.getAttribute('data-for')===sortKey)?(sortDir>0?'\u25b2':'\u25bc'):''; });
    if(selected==null && list.length){ select(list[0]._i); }
  }
  function kvRow(k,v){ if(v==null||v==='')return ''; return '<div class="kv"><span class="k">'+esc(k)+'</span><span>'+esc(v)+'</span></div>'; }
  function badgeSet(title,arr,cls){ if(!arr||!arr.length)return ''; return '<div class="d-sec"><h4>'+esc(title)+'</h4><div class="badges">'+arr.map(function(x){return '<span class="'+(cls||'tag')+'">'+esc(x)+'</span>';}).join('')+'</div></div>'; }
  function select(i){
    selected=i;
    document.querySelectorAll('#rows tr').forEach(function(tr){ tr.classList.toggle('sel', parseInt(tr.getAttribute('data-i'),10)===i); });
    var g=DATA[i]; if(!g){detailEl.innerHTML='<div class="d-empty">Select a game.</div>';return;}
    var cover=g.cover?'<img class="d-cover" src="'+esc(g.cover)+'" alt="">':'';
    var acts='';
    if(g.installed && g.playUri) acts+='<a class="act play" href="'+esc(g.playUri)+'">\u25b6 Play</a>';
    if(g.storeUrl) acts+='<a class="act" href="'+esc(g.storeUrl)+'" target="_blank" rel="noopener noreferrer">Store \u2197</a>';
    var links=g.links&&g.links.length?'<div class="d-sec"><h4>Links</h4><div class="badges">'+g.links.map(function(l){return '<a class="tag lnk" href="'+esc(l.url)+'" target="_blank" rel="noopener noreferrer">'+esc(l.name||l.url)+' \u2197</a>';}).join('')+'</div></div>':'';
    detailEl.innerHTML=cover+'<div class="d-body">'+
      '<h2 class="d-title">'+(g.favorite?'\u2605 ':'')+esc(g.name)+'</h2>'+
      '<div class="d-sub">'+(g.store?'<span class="store-chip" style="background:'+esc(g.color)+'">'+esc(g.store)+'</span>':'')+
        (g.year?'<span>'+esc(g.year)+'</span>':'')+(g.playtime>0?'<span>'+g.playtime+' h</span>':'')+
        (starN(g.rating)>=0?'<span class="stars">'+starsHtml(g.rating)+'</span>':'')+'</div>'+
      (acts?'<div class="d-actions">'+acts+'</div>':'')+
      (g.description?'<p class="d-desc">'+esc(g.description)+'</p>':'')+
      badgeSet('Genres',g.genres,'tag')+badgeSet('Features',g.features,'tag')+badgeSet('Tags',g.tags,'tag')+
      '<div class="d-sec">'+kvRow('Completion',g.completion)+kvRow('Last played',rel(g.lastPlayed))+kvRow('Released',g.released)+
        kvRow('Platforms',(g.platforms||[]).join(', '))+kvRow('Developers',(g.developers||[]).join(', '))+kvRow('Publishers',(g.publishers||[]).join(', '))+kvRow('Series',g.series)+'</div>'+
      links+'</div>';
  }

  rowsEl.addEventListener('click',function(e){ var tr=e.target.closest('tr'); if(tr) select(parseInt(tr.getAttribute('data-i'),10)); });
  var lastHover=null;
  rowsEl.addEventListener('mouseover',function(e){ var tr=e.target.closest('tr'); if(!tr) return; var i=parseInt(tr.getAttribute('data-i'),10); if(i===lastHover) return; lastHover=i; select(i); });
  document.querySelectorAll('th[data-sort]').forEach(function(th){
    th.addEventListener('click',function(){ var k=th.getAttribute('data-sort'); if(sortKey===k){sortDir=-sortDir;}else{sortKey=k;sortDir=1;} render(); });
  });
  [fTitle,fStore,fCat,fRating].forEach(function(el){ el.addEventListener('input',render); el.addEventListener('change',render); });
  render();
})();
</script>
</body>
</html>
'@
}

# --- Details-view export --------------------------------------------
function Invoke-LibraryDetailsViewExport
{
    param($scriptMainMenuItemActionArgs)

    # ---- Configuration ----------------------------------------------
    $exportRoot          = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Playnite Exports'
    $includeHidden       = $false
    $autoOpen            = $true
    $includeDescriptions = $true
    # -----------------------------------------------------------------

    try
    {
        $stamp     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $outDir    = Join-Path $exportRoot "details_$stamp"
        $coversDir = Join-Path $outDir 'covers'
        New-Item -ItemType Directory -Path $coversDir -Force | Out-Null

        $dataList = New-Object System.Collections.Generic.List[object]
        $total    = 0

        foreach ($game in ($PlayniteApi.Database.Games | Sort-Object Name))
        {
            if (-not $includeHidden -and $game.Hidden) { continue }
            $total++
            $dataList.Add((New-GameRecord $game $coversDir $includeDescriptions))
        }

        if ($total -gt 0) {
            $json = ConvertTo-Json -InputObject @($dataList.ToArray()) -Depth 6 -Compress
        } else {
            $json = '[]'
        }
        $json = $json.Replace('</', '<\/')

        $generated = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $html = (Get-DetailsViewHtmlShell).Replace('{{DATA}}', $json).Replace('{{TOTAL}}', "$total games").Replace('{{GENERATED}}', $generated)

        $indexPath = Join-Path $outDir 'index.html'
        $html | Out-File -LiteralPath $indexPath -Encoding UTF8

        $PlayniteApi.Dialogs.ShowMessage("Details view exported: $total games.`n`n$indexPath", "Library Details View")
        if ($autoOpen) { try { Start-Process $indexPath } catch {} }
    }
    catch
    {
        $PlayniteApi.Dialogs.ShowErrorMessage($_.Exception.Message, "Library Details View - Failed")
    }
}

