local innertube = require("innertube")

local STEPS = 4

local session = {}

local function library()
	local step = 0
	local function progress(page)
		nari.send({ progress = math.min((step + page / (page + 1)) / STEPS, 0.99) })
	end
	local tracks = innertube.browse_all(session, "FEmusic_liked_videos", "musicResponsiveListItemRenderer", innertube.song, progress)
	step = 1
	local albums = innertube.browse_all(session, "FEmusic_liked_albums", "musicTwoRowItemRenderer", innertube.album, progress)
	step = 2
	local artists = innertube.browse_all(session, "FEmusic_library_corpus_track_artists", "musicResponsiveListItemRenderer", innertube.artist, progress)
	step = 3
	local followed = innertube.browse_all(session, "FEmusic_library_corpus_artists", "musicResponsiveListItemRenderer", innertube.artist, progress)
	return { tracks = tracks, albums = albums, artists = artists, followed = followed }
end

local actions = {
	account = function(message)
		local candidate = { cookies = innertube.cookie_header(message.text) }
		local name = innertube.account(candidate)
		if not name then
			error("YouTube Music didn't sign you in with these cookies, export them again while signed in", 0)
		end
		session = candidate
		return { account = name, cookies = session.cookies }
	end,
	library = function()
		if not innertube.account(session) then
			return { expired = true }
		end
		return { library = library() }
	end,
	album = function(message)
		return { album = innertube.album_page(session, message.id) }
	end,
	artist = function(message)
		return { artist = innertube.artist_page(session, message.id) }
	end,
	song = function(message)
		return { song = innertube.song_details(message.id) }
	end,
	search = function(message)
		return { result = innertube.search(session, message.query) }
	end,
	discover = function(message)
		local sections = innertube.home(session)
		local ok, lives = pcall(innertube.lives, session, "24/7 radio")
		if ok and #lives > 0 then
			table.insert(sections, 2, { title = "Live radio", kind = "tracks", items = lives })
		end
		return { sections = sections }
	end,
	like = function(message)
		if message.kind == "artist" then
			innertube.follow(session, message.id, message.on)
		elseif message.kind == "album" then
			local playlist = (message.playlist_id or "") ~= "" and message.playlist_id or innertube.album_page(session, message.id).playlist_id
			innertube.like(session, { playlistId = playlist }, message.on)
		else
			innertube.like(session, { videoId = message.id }, message.on)
		end
		return {}
	end,
	playlists = function(message)
		return { playlists = innertube.browse_all(session, "FEmusic_liked_playlists", "musicTwoRowItemRenderer", innertube.playlist) }
	end,
	playlist = function(message)
		return { tracks = innertube.playlist_tracks(session, message.id) }
	end,
	create = function(message)
		return { id = innertube.create_playlist(session, message.name) }
	end,
	delete = function(message)
		innertube.delete_playlist(session, message.id)
		return {}
	end,
	edit = function(message)
		return { added = innertube.edit_playlist(session, message.id, message.actions) }
	end,
}

nari.on("message", function(message)
	if message.action ~= "account" then
		if not message.cookies then
			session = {}
		elseif not session.cookies then
			session = { cookies = message.cookies }
		end
	end
	local before = session.cookies
	local ok, result = pcall(actions[message.action], message)
	if not ok then
		result = { error = tostring(result):gsub("^.-:%d+: ", "") }
	end
	if session.cookies ~= before then
		result.cookies = session.cookies
	end
	result.request = message.request
	nari.send(result)
end)
