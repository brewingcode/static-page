commify = (s) -> s.toString().replace /// \B (?= (\d{3})+ (?!\d) ) ///g, ','

load = ->
  if data = localStorage.getItem('bgg')
    JSON.parse(data)
  else
    {}

save = ->
  data = JSON.stringify
    plays: app.plays
    selected: app.selected
  localStorage.setItem('bgg', data)

app = new Vue
  el: '#app'
  template:'#app'
  vuetify: new Vuetify()

  data: ->
    saved = load()
    headers:
      players: [
        { text: 'Player Name', value: 'name' }
        { text: 'Number of Games Played', value: 'count' }
      ]
      games: [
        { text: 'Game', value: 'name' }
        { text: 'Date', value: 'date' }
        { text: 'Players', value: 'players' }
        { text: 'Location', value: 'location'}
      ]
    plays: saved.plays or bgg.plays.play
    selected: saved.selected or []

  watch:
    plays: -> save()
    selected: -> save()

  computed:
    players: ->
      names = {}
      @plays.forEach (play) ->
        addName = (player) ->
          names[player.name] ?= []
          names[player.name].push play.id
        if Array.isArray(play.players)
          play.players.forEach addName
        else if play.players?.player
          addName play.players.player

      return _(names)
        .keys()
        .map (k) ->
          name: k
          plays: names[k]
          count: commify names[k].length
        .sortBy (p) ->
          +p.count
        .reverse()
        .value()

    commonGames: ->
      ids = _.intersection ...@selected.map (player) -> player.plays
      games = []
      @plays.forEach (play) ->
        if play.id in ids
          players = _(play.players)
            .map (p) -> p.name
            .sortBy (p) -> p.toLowerCase()
            .join '<br>'

          games.push
            name: play.item.name
            gameid: play.item.objectid
            playid: play.id
            date: play.date
            players: players
            location: play.location
      return games

    stats: ->
      return
        'Number of games': @commonGames.length


