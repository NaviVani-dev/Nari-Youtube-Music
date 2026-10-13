local COVER = 720
local THUMB = 300
local CENTER = 1
local EXPAND_FILL = 3
local LIKED = { track = "tracks", album = "albums", artist = "followed" }
local PRIVATE = { private = true }

nari.log_color("#ff0033")

local worker = nari.thread("library.lua")
nari.thread("resolver.lua")

local state = {
	cookies = nari.get("cookies"),
	account = nari.get("account"),
	library = nari.get("library"),
	loading = false,
	progress = 0,
}
if state.library and state.library.version ~= 2 then
	state.library = nil
end
local index = { tracks = {}, albums = {}, covers = nari.get("covers") or {} }
local fetching = {}
local covers_dirty = false
local albums_cache = {}
local playlists = {}
local entries = {}
local waiting = {}
local pending = {}
local requests = 0
local me

local function ask(message, handler)
	requests = requests + 1
	message.request = requests
	pending[requests] = handler
	worker:send(message)
end

worker:on_message(function(message)
	if message.progress then
		state.progress = message.progress
		return
	end
	if message.cookies and state.cookies then
		state.cookies = message.cookies
		nari.set("cookies", message.cookies, PRIVATE)
	end
	local handler = pending[message.request]
	pending[message.request] = nil
	if handler then
		handler(message)
	end
end)

worker:on_error(function(problem)
	nari.warn("the library worker stopped: " .. problem)
end)

local function remember(item)
	if not item or not item.thumbnail or item.thumbnail == "" then
		return item
	end
	if index.covers[item.id] ~= item.thumbnail then
		index.covers[item.id] = item.thumbnail
		covers_dirty = true
	end
	if item.album_id and item.album_id ~= "" and not index.covers[item.album_id] then
		index.covers[item.album_id] = item.thumbnail
		covers_dirty = true
	end
	return item
end

local function remember_all(list)
	for _, item in ipairs(list or {}) do
		remember(item)
		if item.album_id and item.duration then
			index.tracks[item.id] = index.tracks[item.id] or item
		elseif item.title then
			index.albums[item.id] = index.albums[item.id] or item
		end
	end
	return list or {}
end

local function stamp(list)
	local now = os.time()
	for position, item in ipairs(list) do
		item.liked_at = now - position
	end
end

local function save_covers()
	if covers_dirty then
		covers_dirty = false
		nari.set("covers", index.covers)
	end
end

local function build_index()
	index = { tracks = {}, albums = {}, covers = index.covers }
	if not state.library then
		return
	end
	table.sort(state.library.tracks, function(first, second) return first.sort_title < second.sort_title end)
	table.sort(state.library.albums, function(first, second) return first.title:lower() < second.title:lower() end)
	table.sort(state.library.artists, function(first, second) return first.name:lower() < second.name:lower() end)
	for _, track in ipairs(state.library.tracks) do
		index.tracks[track.id] = track
		remember(track)
	end
	for _, album in ipairs(state.library.albums) do
		index.albums[album.id] = album
		remember(album)
	end
	for _, artist in ipairs(state.library.artists) do
		remember(artist)
	end
	for _, artist in ipairs(state.library.followed) do
		remember(artist)
	end
end

local function by_artist(list, id, name)
	local found = {}
	for _, item in ipairs(list) do
		local matches = item.artist_id == id
		for _, artist in ipairs(item.artists or {}) do
			matches = matches or artist == name
		end
		if matches or (item.artist or "") == name then
			table.insert(found, item)
		end
	end
	return found
end

local function build_artists()
	for _, artist in ipairs(state.library.artists) do
		local albums = by_artist(state.library.albums, artist.id, artist.name)
		artist.album_count = #albums
		artist.cover_album_id = albums[1] and albums[1].id or artist.id
	end
end

local function finish_waiting()
	local handlers = waiting
	waiting = {}
	for _, handler in ipairs(handlers) do
		handler()
	end
end

local function when_loaded(done, read)
	if state.library or not state.loading then
		return read()
	end
	table.insert(waiting, function() done(read()) end)
end

local function open_settings()
	Main:change_page(Main.Pages.Settings, Dictionary({ category = "library" }))
end

local function sign_out()
	state.cookies, state.account, state.library = nil, nil, nil
	for _, key in ipairs({ "cookies", "account", "library", "covers" }) do
		nari.set(key, nil)
	end
	index.covers = {}
	build_index()
	me.settings_changed:emit()
	me.library_changed:emit()
end

local function refresh()
	if not state.cookies or state.loading then
		return
	end
	state.loading = true
	state.progress = 0
	ask({ action = "library", cookies = state.cookies }, function(message)
		state.loading = false
		if message.expired then
			nari.warn("the session expired, signing out")
			Snackbar.post("Your YouTube Music session expired", "Search and playback still work. Tap to sign in again", open_settings)
			sign_out()
		elseif message.error then
			nari.warn("the library couldn't be loaded: " .. message.error)
		end
		if message.expired or message.error then
			finish_waiting()
			if me then
				me.library_ready:emit(false, message.error or "the session expired")
			end
			return
		end
		stamp(message.library.tracks)
		stamp(message.library.albums)
		stamp(message.library.followed)
		message.library.version = 2
		state.library = message.library
		build_index()
		build_artists()
		nari.set("library", state.library)
		save_covers()
		finish_waiting()
		if me then
			me.library_changed:emit()
			me.library_ready:emit(true, "")
		end
	end)
end

local function field(placeholder)
	local edit = NariLineEdit.new()
	edit.placeholder_text = placeholder
	edit.secret = true
	edit.custom_minimum_size = Vector2(0, 112)
	edit.font_size = 40
	edit.bg_color = ThemeEngine.Colors.PanelBg
	edit.fg_color = ThemeEngine.Colors.PanelFg
	return edit
end

local LOGIN = "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com"

local function label(text, size)
	local line = NariLabel.new()
	line.text = text
	line.font_size = size
	line.autowrap_mode = 3
	return line
end

local function sign_in(text, done)
	ask({ action = "account", text = text }, function(message)
		if message.error then
			return done(message.error)
		end
		state.cookies, state.account = message.cookies, message.account
		nari.set("cookies", message.cookies, PRIVATE)
		nari.set("account", message.account)
		me.settings_changed:emit()
		refresh()
		done()
	end)
end

local function import_cookies()
	local dialog = Dialog.menu("YouTube Music", "Import your cookies.txt")
	dialog.content:add_theme_constant_override("separation", 16)
	local status = label("", 36)
	status.horizontal_alignment = CENTER
	status.visible = false
	local edit = field("Or paste the cookies here")
	local function check(text)
		status.visible = true
		status.text = "Checking your account..."
		sign_in(text, function(problem)
			if problem then
				status.text = problem
			else
				dialog:close()
			end
		end)
	end
	local import = Dialog.text_button("Import cookies.txt", function()
		nari.await(Plugins:pick_text({ "txt" }), function(text)
			if text ~= "" then
				check(text)
			end
		end)
	end)
	import.size_flags_horizontal = EXPAND_FILL
	dialog.content:add_child(import)
	dialog.content:add_child(edit)
	dialog.content:add_child(status)
	dialog:add_button("Paste", function()
		edit.text = DisplayServer:clipboard_get()
	end, Dialog.Style.NORMAL, false)
	dialog:add_button("Sign in", function()
		check(edit.text)
	end, Dialog.Style.PRIMARY, false)
	dialog:popup()
end

local function open_sign_in()
	local signing = false
	local web = nari.webview({
		title = "Sign in to YouTube Music",
		url = LOGIN,
		incognito = true,
		desktop_mode = OS:get_name() ~= "Android",
		on_load = function(web)
			if signing then
				return
			end
			local cookies = web:cookies("https://music.youtube.com")
			if not cookies:find("SAPISID=", 1, true) then
				return
			end
			signing = true
			web:close()
			sign_in(cookies, function(problem)
				if problem then
					Snackbar.post("YouTube Music didn't sign you in", problem)
				end
			end)
		end,
	})
	if not web then
		import_cookies()
	end
end

local function sized(url, size)
	if url:match("googleusercontent%.com") or url:match("ggpht%.com") then
		return url:gsub("=[^=/]*$", "") .. "=w" .. size .. "-h" .. size .. "-l90-rj"
	end
	local video = url:match("i%.ytimg%.com/vi[_webp]*/([%w_%-]+)/")
	if video then
		return "https://i.ytimg.com/vi/" .. video .. (size == THUMB and "/mqdefault.jpg" or "/hq720.jpg"), "https://i.ytimg.com/vi/" .. video .. "/mqdefault.jpg"
	end
	return (url:gsub("/vi_webp/", "/vi/"):gsub("%.webp", ".jpg"))
end

local function squared(path)
	local file = io.open(path .. ".part", "rb")
	local magic = file and file:read(12) or ""
	if file then
		file:close()
	end
	local typed = path .. (magic:sub(1, 4) == "\137PNG" and ".png" or magic:sub(9, 12) == "WEBP" and ".webp" or ".jpg")
	os.rename(path .. ".part", typed)
	local image = Image.load_from_file(typed)
	os.remove(typed)
	if not image then
		return false
	end
	local width, height = image:get_width(), image:get_height()
	if width ~= height then
		local side = math.min(width, height)
		image = image:get_region(Rect2((width - side) // 2, (height - side) // 2, side, side))
	end
	return image:save_jpg(path, 0.9) == 0
end

local function cover_file(kind, id, thumb)
	return "covers/" .. kind .. "_" .. id:gsub("[^%w_%-]", "_") .. (thumb and "_thumb" or "") .. ".jpg"
end

local function failed(what, message)
	nari.warn(what .. " failed: " .. message.error)
end

local provider = {
	id = "youtube_music",
	name = "YouTube Music",
	description = "Songs, albums and artists from your YouTube Music library",
	icon = "icon.jpg",
	color = "#ff0033",
	streams = true,
	auto_discover = false,
}

function provider.is_configured()
	return true
end

function provider.is_loading()
	return state.loading and not state.library
end

function provider.is_ready()
	return state.library ~= nil or not state.cookies
end

function provider.get_status()
	return Dictionary({ progress = state.progress })
end

function provider.setup_entries()
	return {
		{
			title = "YouTube Music account",
			description = state.cookies and ("Signed in as " .. (state.account or "you"))
				or "Not signed in. Search, playback and Discover work, sign in for your library",
			icon = "res://assets/icons/artist.svg",
			value = function() return state.cookies and "Change" or "Sign in" end,
			action = open_sign_in,
		},
	}
end

function provider.settings_entries(self)
	local entries = provider.setup_entries()
	table.insert(entries, {
		title = "Import cookies.txt",
		description = "Sign in with cookies exported from a browser",
		icon = "res://assets/icons/upload.svg",
		action = import_cookies,
	})
	if state.cookies then
		table.insert(entries, {
			title = "Refresh library",
			description = state.loading and "Loading your library..." or "Load your songs, albums and artists again",
			icon = "res://assets/icons/repeat.svg",
			action = refresh,
		})
		table.insert(entries, {
			title = "Sign out",
			description = "Forget your YouTube Music cookies and library",
			icon = "res://assets/icons/close.svg",
			action = function() Dialog.confirm("Sign out of YouTube Music?", "Sign out", sign_out, true) end,
		})
	end
	return entries
end

function provider.get_tracks(self, done)
	return when_loaded(done, function() return state.library and state.library.tracks or {} end)
end

function provider.get_albums(self, done)
	return when_loaded(done, function() return state.library and state.library.albums or {} end)
end

function provider.get_artists(self, done)
	return when_loaded(done, function() return state.library and state.library.artists or {} end)
end

function provider.get_album(self, id, done)
	if albums_cache[id] then
		return albums_cache[id]
	end
	ask({ action = "album", cookies = state.cookies, id = id }, function(message)
		local album = message.album
		if not album then
			nari.warn("album " .. id .. " couldn't be loaded: " .. tostring(message.error))
			return done(Dictionary())
		end
		local known = index.albums[id]
		album.title = album.title ~= "" and album.title or (known and known.title or "")
		remember(album)
		for _, track in ipairs(album.tracks) do
			index.tracks[track.id] = index.tracks[track.id] or track
			remember(track)
		end
		albums_cache[id] = album
		save_covers()
		done(album)
	end)
end

local function local_artist(id)
	if not state.library then
		return Dictionary()
	end
	local artist
	for _, candidate in ipairs(state.library.artists) do
		if candidate.id == id then
			artist = candidate
		end
	end
	local name = artist and artist.name or ""
	local tracks = by_artist(state.library.tracks, id, name)
	if not artist and tracks[1] then
		name = tracks[1].artists[1] or tracks[1].artist
		tracks = by_artist(state.library.tracks, id, name)
	end
	local albums = by_artist(state.library.albums, id, name)
	local duration = 0
	for _, track in ipairs(tracks) do
		duration = duration + track.duration
	end
	return Dictionary({
		id = id,
		name = name,
		albums = albums,
		tracks = tracks,
		album_count = #albums,
		song_count = #tracks,
		duration = duration,
		cover_album_id = albums[1] and albums[1].id or id,
	})
end

function provider.get_artist(self, id, done)
	ask({ action = "artist", cookies = state.cookies, id = id }, function(message)
		if message.error or message.artist.name == "" then
			if message.error then
				failed("loading artist " .. id, message)
			end
			return done(local_artist(id))
		end
		remember(message.artist)
		remember_all(message.artist.albums)
		remember_all(message.artist.tracks)
		remember_all(message.artist.related)
		for _, section in ipairs(message.artist.sections or {}) do
			remember_all(section.items)
		end
		save_covers()
		done(message.artist)
	end)
end

function provider.get_song(self, id, done)
	if index.tracks[id] then
		return index.tracks[id]
	end
	ask({ action = "song", id = id }, function(message)
		if message.error then
			failed("loading song " .. id, message)
			return done(Dictionary())
		end
		done(remember_all({ message.song })[1])
	end)
end

function provider.search(self, query, filters, done)
	local terms = { query }
	for _, key in ipairs({ "title", "artist", "album", "genre" }) do
		if filters and filters[key] and filters[key] ~= "" then
			table.insert(terms, filters[key])
		end
	end
	local text = table.concat(terms, " "):match("^%s*(.-)%s*$")
	if text == "" then
		return { tracks = {}, albums = {}, artists = {} }
	end
	ask({ action = "search", cookies = state.cookies, query = text }, function(message)
		if message.error then
			failed("searching", message)
			return done({ tracks = {}, albums = {}, artists = {} })
		end
		for _, key in ipairs({ "tracks", "albums", "artists" }) do
			remember_all(message.result[key])
		end
		save_covers()
		done(message.result)
	end)
end

function provider.get_discover(self, done)
	ask({ action = "discover", cookies = state.cookies }, function(message)
		if message.error then
			failed("loading Discover", message)
			return done({})
		end
		for position, section in ipairs(message.sections) do
			local quick = section.title == "Quick picks"
			section.id = quick and "quick_picks" or "home_" .. position
			section.order = quick and 0 or 14 + position
			remember_all(section.items)
		end
		save_covers()
		done(message.sections)
	end)
end

function provider.get_liked(self, kind, done)
	return when_loaded(done, function() return state.library and state.library[LIKED[kind]] or {} end)
end

function provider.set_liked(self, kind, id, on, done)
	if not state.cookies then
		return true
	end
	local album = index.albums[id]
	ask({ action = "like", cookies = state.cookies, kind = kind, id = id, on = on, playlist_id = album and album.playlist_id or nil }, function(message)
		if message.error then
			failed("saving the like", message)
			return done(true)
		end
		local library = state.library
		if library and LIKED[kind] then
			local list = library[LIKED[kind]]
			local item
			for position = #list, 1, -1 do
				if list[position].id == id then
					item = table.remove(list, position)
				end
			end
			item = item or (kind == "track" and index.tracks[id]) or (kind == "album" and album) or nil
			if on and item then
				item.liked_at = os.time()
				table.insert(list, 1, item)
			end
			build_index()
			build_artists()
			nari.set("library", library)
			me.library_changed:emit()
		end
		done(true)
	end)
end

function provider.media_uri(self, track, quality)
	return "ytmusic:" .. track.id .. "?quality=" .. quality
end

function provider.get_raw_lyrics()
	return Dictionary()
end

function provider.playable(self, tracks)
	local list = {}
	for _, track in ipairs(tracks) do
		local cover_id = track.album_id ~= "" and track.album_id or track.id
		local url = index.covers[cover_id] or track.thumbnail or ""
		table.insert(list, {
			id = track.id,
			title = track.title,
			artist = track.artist,
			artist_id = track.artist_id,
			album = track.album,
			album_id = track.album_id,
			duration = track.duration,
			live = track.live or nil,
			uri = provider.media_uri(self, track, SettingsManager.playback.stream_quality),
			file_name = track.id .. ".m4a",
			cover = nari.plugin.data .. "/" .. cover_file(track.album_id ~= "" and "album" or "song", cover_id, false),
			cover_url = url ~= "" and not url:find("i.ytimg.com/vi", 1, true) and sized(url, COVER) or "",
			public_cover_url = url ~= "" and sized(url, COVER) or nil,
			share_url = "https://music.youtube.com/watch?v=" .. track.id,
		})
	end
	return list
end

function provider.get_cover_path(self, kind, id, thumb, done)
	local file = cover_file(kind, id, thumb)
	local path = nari.plugin.data .. "/" .. file
	if FileAccess:file_exists(path) then
		return path
	end
	local url = index.covers[id]
	if (not url or url == "") and kind == "song" and id:match("^[%w_%-]+$") and #id == 11 then
		url = "https://i.ytimg.com/vi/" .. id .. "/hqdefault.jpg"
	end
	if not url or url == "" then
		return ""
	end
	if fetching[file] then
		table.insert(fetching[file], done)
		return
	end
	fetching[file] = { done }
	local function finish(result)
		local waiting = fetching[file]
		fetching[file] = nil
		for _, handler in ipairs(waiting) do
			handler(result)
		end
	end
	local function fetch(source, fallback)
		nari.http({ url = source, save = file .. ".part" }, function(response)
			if response and response.status == 200 and squared(path) then
				return finish(path)
			end
			os.remove(path .. ".part")
			if fallback then
				return fetch(fallback)
			end
			finish("")
		end)
	end
	fetch(sized(url, thumb and THUMB or COVER))
end

local RECENT = 120

local recent = {}

local function recent_of(id)
	local edits = recent[id]
	if edits and os.time() - edits.at < RECENT then
		return edits
	end
	recent[id] = nil
end

local function touch(id)
	local edits = recent_of(id) or { added = {}, removed = {} }
	edits.at = os.time()
	recent[id] = edits
	return edits
end

local function playlist_request(action, message, done, result, saved)
	if not state.cookies then
		return done(result)
	end
	message.action = action
	message.cookies = state.cookies
	ask(message, function(answer)
		if answer.error then
			nari.warn(action .. " failed: " .. answer.error)
			return done(result)
		end
		if saved then
			saved(answer)
		end
		done(answer.id or true)
	end)
end

function provider.get_playlists(self, done)
	if not state.cookies then
		return {}
	end
	ask({ action = "playlists", cookies = state.cookies }, function(message)
		if message.error then
			nari.warn("playlists couldn't be loaded: " .. message.error)
			return done({})
		end
		local list = {}
		local listed = {}
		for _, playlist in ipairs(message.playlists) do
			local edits = recent_of(playlist.id)
			if not (edits and edits.deleted) then
				playlist.name = edits and edits.name or playlist.name
				listed[playlist.id] = true
				table.insert(list, playlist)
			end
		end
		for id, edits in pairs(recent) do
			if recent_of(id) and edits.created and not edits.deleted and not listed[id] then
				table.insert(list, 1, { id = id, name = edits.name, song_count = 0, duration = 0, modified = 0, cover_album_ids = { id }, image = "" })
			end
		end
		playlists = {}
		for _, playlist in ipairs(list) do
			playlists[playlist.id] = playlist
			remember(playlist)
		end
		save_covers()
		done(list)
	end)
end

function provider.get_playlist(self, id, done)
	ask({ action = "playlist", cookies = state.cookies, id = id }, function(message)
		if message.error then
			nari.warn("playlist " .. id .. " couldn't be loaded: " .. message.error)
			return done(Dictionary())
		end
		local edits = recent_of(id) or { added = {}, removed = {} }
		local known = playlists[id] or {}
		local tracks, present, duration = {}, {}, 0
		entries[id] = entries[id] or {}
		for _, track in ipairs(message.tracks) do
			if not edits.removed[track.id] then
				entries[id][track.id] = track.set_video_id
				index.tracks[track.id] = index.tracks[track.id] or track
				remember(track)
				present[track.id] = true
				table.insert(tracks, track)
			end
		end
		for song_id in pairs(edits.added) do
			if not present[song_id] and index.tracks[song_id] then
				table.insert(tracks, index.tracks[song_id])
			end
		end
		for _, track in ipairs(tracks) do
			duration = duration + track.duration
		end
		done({
			id = id,
			name = edits.name or known.name or "",
			song_count = #tracks,
			duration = duration,
			modified = #tracks,
			cover_album_ids = { id },
			image = "",
			tracks = tracks,
		})
	end)
end

function provider.create_playlist(self, name, done)
	playlist_request("create", { name = name }, done, "", function(answer)
		local edits = touch(answer.id)
		edits.created, edits.name = true, name
	end)
end

function provider.delete_playlist(self, id, done)
	playlist_request("delete", { id = id }, done, true, function()
		touch(id).deleted = true
	end)
end

function provider.rename_playlist(self, id, name, done)
	playlist_request("edit", { id = id, actions = { { action = "ACTION_SET_PLAYLIST_NAME", playlistName = name } } }, done, true, function()
		touch(id).name = name
	end)
end

function provider.add_to_playlist(self, id, song_ids, done)
	local actions = {}
	for _, song_id in ipairs(song_ids) do
		table.insert(actions, { action = "ACTION_ADD_VIDEO", addedVideoId = song_id, dedupeOption = "DEDUPE_OPTION_SKIP" })
	end
	playlist_request("edit", { id = id, actions = actions }, done, true, function(answer)
		local edits = touch(id)
		entries[id] = entries[id] or {}
		for song_id, set_video_id in pairs(answer.added or {}) do
			entries[id][song_id] = set_video_id
		end
		for _, song_id in ipairs(song_ids) do
			edits.added[song_id] = true
			edits.removed[song_id] = nil
		end
	end)
end

function provider.remove_from_playlist(self, id, song_id, done)
	local function remove()
		local set_video_id = entries[id] and entries[id][song_id]
		if not set_video_id or set_video_id == "" then
			nari.log(song_id .. " isn't in playlist " .. id)
			return done(true)
		end
		playlist_request("edit", { id = id, actions = { { action = "ACTION_REMOVE_VIDEO", setVideoId = set_video_id, removedVideoId = song_id } } }, done, true, function()
			local edits = touch(id)
			edits.removed[song_id] = true
			edits.added[song_id] = nil
			entries[id][song_id] = nil
		end)
	end
	if entries[id] and entries[id][song_id] then
		return remove()
	end
	provider.get_playlist(self, id, function() remove() end)
end

me = nari.music_provider(provider)
build_index()
if state.library then
	build_artists()
end
refresh()
