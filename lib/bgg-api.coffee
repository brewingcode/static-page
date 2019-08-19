# https://boardgamegeek.com/wiki/page/BGG_XML_API2

pr = require 'bluebird'
{ execSync, execAsync } = pr.promisifyAll require 'child_process'
fs = require 'fs'
mkdirp = require 'mkdirp'
knex = require 'knex'
moment = require 'moment'

datadir = '/tmp/bgg'

dbh = null
db = (args...) -> if args.length then dbh(args...) else dbh
do ->
  dbh = await knex
    client: 'sqlite3'
    connection:
      filename: "#{datadir}/db.sqlite"
    useNullAsDefault: true

  makeTable = (name, cols) ->
    dbh.schema.hasTable(name).then (t) ->
      if not t
        dbh.schema.createTable name, (t) -> cols(t)

  await makeTable 'users', (t) ->
    t.string('bgg_name').notNullable().unique()
    t.json 'all_plays'
    t.timestamps true, true
  await makeTable 'remap_names', (t) ->
    t.string('bgg_name').notNullable()
    t.string('from_api')
    t.string('change_to')
    t.timestamps true, true

fixXml = (n) ->
  log = -> 0 #console.log
  if Array.isArray(n)
    log 'array:', n.length
    return n.map fixXml
  else if typeof n is 'object'
    log 'object:', Object.keys(n)
    for k,v of n
      if m = k.match /^@(.*)/
        log 'renaming', k, 'to', m[1]
        delete n[k]
        k = m[1]
        n[k] = v
      if m = k.match /(.*)s$/
        if Array.isArray(v[m[1]]) and Object.keys(v).length is 1
          log 'restructuring lonely array'
          n[k] = v[m[1]]
      n[k] = fixXml n[k]
    return n
  else
    log 'scalar:', n
    return n

fetchUrl = (url) ->
  new pr (resolve) ->
    resp = await execAsync("curl -qsS '#{url}'")
    try
      json = execSync('xq .', { input:resp })
      resp = fixXml JSON.parse(json)
      if resp.div?.class is 'messagebox error'
        console.error "api error:", url, resp.div['#text']
      resolve resp

    catch e
      f = "/tmp/failed-bgg-parse-#{moment().valueOf()}"
      fs.writeFileSync(f, resp)
      console.error "response parse failure (see #{f}):", e
      throw e

onePage = (username, page) ->
  await fetchUrl "https://www.boardgamegeek.com/xmlapi2/plays?username=#{username}&page=#{page or 1}"

oneThing = (id) ->
  await fetchUrl "https://www.boardgamegeek.com/xmlapi2/thing?id=#{id}"

allPlays = (username) ->
  first = await onePage(username)
  if not first.plays?.play
    return
      error: first.div['#text']
  totalpages = Math.floor(+first.total / 100) + 1
  if totalpages > 1
    prs = await pr.all [2 .. totalpages].map (page) ->
      await onePage(username, page)
    prs.forEach (page, i) ->
      if not page.plays.play
        console.error "no plays on page #{i}"
      else
        first.plays.play.push ...page.plays.play
  delete first.plays.page
  return first.plays

cachedPlays = (username, age) ->
  age ?= 60

  rows = await db('users').select().where(bgg_name:username)
  if rows.length is 1
    if moment.utc(rows[0].updated_at).isBefore(moment().subtract(age, 'minutes'))
      plays = await allPlays(username)
      await db('users').where
        bgg_name:username
      .update
        all_plays:JSON.stringify(plays)
    else
      plays = JSON.parse(rows[0].all_plays)
  else
    plays = await allPlays(username)
    await db('users').insert
      all_plays:JSON.stringify(plays)
      bgg_name:username

  return plays

fixNames = (username) ->
  rows = if username
    await db('users').select().where(bgg_name:username)
  else
    await db('users').select()

  console.log "remapping #{rows.length} users"
  await pr.all rows.map (row) ->
    remap_rows = await db('remap_names').select().where(bgg_name:row.bgg_name)
    console.log "#{row.bgg_name} has #{remap_rows.length} remaps"
    return unless remap_rows.length > 0

    remap = {}
    remap_rows.forEach (x) -> remap[x.from_api] = x.change_to
    fixName = (player) ->
      if remap[player.name]
        console.log "remapping #{player.name} -> #{remap[player.name]} for #{row.bgg_name}"
        player.name = remap[player.name]
        remap['//'] = 1

    plays = JSON.parse(row.all_plays)
    plays.play?.forEach (play) ->
      if Array.isArray(play.players)
        play.players.forEach fixName
      else if play.players?.player
        fixName play.players.player

    if remap['//']
      await db('users').where
        bgg_name:row.bgg_name
      .update
        all_plays:JSON.stringify(plays)

module.exports = { fixXml, onePage, allPlays, oneThing, db, cachedPlays, fixNames }

unless module.parent
  [ username, age ] = process.argv.slice(2)
  unless username
    console.error "username required"
    process.exit(1)
  pr.delay(300).then ->
    # plays = await cachedPlays username, if age then +age else null
    # console.log "#{plays.total} plays found"
    await fixNames()
  .finally ->
    db()?.destroy()
