local innertube = {}

local MUSIC = "https://music.youtube.com"
local YOUTUBE = "https://www.youtube.com"
local ACCOUNTS = "https://accounts.youtube.com"
local ROTATE_EVERY = 600
local MUSIC_VERSION = "1.20260928.13.00"
local DESKTOP = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
local VISION = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
local MAX_PAGES = 400
local ARTIST_PAGES = { MUSIC_PAGE_TYPE_ARTIST = true, MUSIC_PAGE_TYPE_USER_CHANNEL = true }
local SEARCH = {
	tracks = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D",
	albums = "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D",
	artists = "EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D",
}
local VIDEOS = "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
local SEARCH_ALBUMS = 12
local HOME_PAGES = 4
local BITRATES = { high = 320, normal = 192, low = 128 }

function innertube.sapisid(cookies)
	local found = {}
	for name, value in cookies:gmatch("([^=;%s]+)=([^;]*)") do
		found[name] = value
	end
	return found.SAPISID or found["__Secure-3PAPISID"]
end

function innertube.cookie_header(raw)
	local text = raw:gsub("^\239\187\191", ""):match("^%s*(.-)%s*$")
	local names, values = {}, {}
	local function add(domain, name, value)
		if name and name ~= "" and not name:match("^ST%-") and (domain or ""):find("youtube.com", 1, true) then
			if not values[name] then
				table.insert(names, name)
			end
			values[name] = value or ""
		end
	end
	if text:match("^[%[{]") then
		local ok, list = pcall(nari.json_decode, text)
		list = ok and type(list) == "table" and (list.cookies or list) or {}
		for _, cookie in ipairs(list) do
			add(cookie.domain, cookie.name, tostring(cookie.value or ""))
		end
	elseif text:find("\t", 1, true) then
		for line in text:gmatch("[^\r\n]+") do
			local fields = {}
			for value in ((line:gsub("^#HttpOnly_", "")) .. "\t"):gmatch("([^\t]*)\t") do
				table.insert(fields, value)
			end
			if #fields >= 6 and not fields[1]:match("^#") then
				add(fields[1], fields[6], fields[7])
			end
		end
	else
		local header = text:gsub("^[Cc]ookie:%s*", "")
		if header:find("[\r\n]") or not header:find("^[^=;%s]+=") then
			error("This isn't a cookies.txt file or a Cookie header", 0)
		end
		for name, value in header:gmatch("([^=;%s]+)=([^;]*)") do
			add("youtube.com", name, value)
		end
	end
	if #names == 0 then
		error("There are no youtube.com cookies in this file, export them while music.youtube.com is open", 0)
	end
	local parts = {}
	for _, name in ipairs(names) do
		table.insert(parts, name .. "=" .. values[name])
	end
	return table.concat(parts, "; ")
end

function innertube.find(node, key, found)
	found = found or {}
	if type(node) ~= "table" then
		return found
	end
	if node[1] ~= nil then
		for _, value in ipairs(node) do
			innertube.find(value, key, found)
		end
		return found
	end
	for name, value in pairs(node) do
		if name == key then
			table.insert(found, value)
		else
			innertube.find(value, key, found)
		end
	end
	return found
end

local function text(node)
	if type(node) ~= "table" then
		return ""
	end
	if node.simpleText then
		return node.simpleText
	end
	local parts = {}
	for _, run in ipairs(node.runs or {}) do
		table.insert(parts, run.text or "")
	end
	return table.concat(parts)
end

local function link(run)
	local browse = run.navigationEndpoint and run.navigationEndpoint.browseEndpoint
	if not browse then
		return nil, nil
	end
	local configs = browse.browseEndpointContextSupportedConfigs
	local music = configs and configs.browseEndpointContextMusicConfig
	return browse.browseId, music and music.pageType
end

local function thumbnail(node)
	local best, width = "", 0
	for _, list in ipairs(innertube.find(node, "thumbnails")) do
		for _, candidate in ipairs(list) do
			if (candidate.width or 0) >= width and candidate.url then
				best, width = candidate.url, candidate.width or 0
			end
		end
	end
	return best
end

local function clock(value)
	local total = 0
	for part in value:gmatch("%d+") do
		total = total * 60 + tonumber(part)
	end
	return total * 1000
end

local function is_live(renderer)
	return innertube.find(renderer, "liveBadgeRenderer")[1] ~= nil
end

local function artist_id(id)
	return ((id or ""):gsub("^MPLA", ""))
end

local function request(url, headers, body)
	local response, problem = nari.http({ method = "POST", url = url, headers = headers, body = nari.json_encode(body) })
	if not response then
		error("YouTube Music can't be reached: " .. problem)
	end
	if response.status == 401 or response.status == 403 then
		error("YouTube Music refused the session, paste new cookies")
	end
	if response.status ~= 200 then
		error("YouTube Music answered " .. response.status)
	end
	return nari.json_decode(response.body), response
end

function innertube.absorb(cookies, header)
	if not header or header == "" then
		return cookies
	end
	local names, values = {}, {}
	for name, value in cookies:gmatch("([^=;%s]+)=([^;]*)") do
		table.insert(names, name)
		values[name] = value
	end
	for line in header:gmatch("[^\n]+") do
		local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
		local domain = line:match("[Dd]omain=([^;]+)")
		local year = tonumber(line:match("[Ee]xpires=[^;]-(%d%d%d%d)"))
		if name and not name:match("^ST%-") and (not domain or domain:find("youtube.com", 1, true)) then
			if line:match("[Mm]ax%-[Aa]ge=0%f[^%d]") or (year and year < 2000) then
				values[name] = nil
			else
				if values[name] == nil then
					table.insert(names, name)
				end
				values[name] = value
			end
		end
	end
	local parts, added = {}, {}
	for _, name in ipairs(names) do
		if values[name] and not added[name] then
			added[name] = true
			table.insert(parts, name .. "=" .. values[name])
		end
	end
	return table.concat(parts, "; ")
end

local function rotate(session)
	if os.time() - (session.rotated or 0) < ROTATE_EVERY then
		return
	end
	session.rotated = os.time()
	local response = nari.http({
		method = "POST",
		url = ACCOUNTS .. "/RotateCookies",
		headers = { ["Content-Type"] = "application/json", ["Origin"] = ACCOUNTS, ["Cookie"] = session.cookies, ["User-Agent"] = DESKTOP },
		body = '[000,"-0000000000000000000"]',
	})
	if response and response.status == 200 then
		session.cookies = innertube.absorb(session.cookies, response.headers["set-cookie"])
	end
end

function innertube.music(session, endpoint, body, query)
	body.context = { client = { clientName = "WEB_REMIX", clientVersion = MUSIC_VERSION, hl = "en", gl = "US", visitorData = innertube.visitor } }
	local headers = {
		["X-Goog-Visitor-Id"] = innertube.visitor,
		["Content-Type"] = "application/json",
		["Origin"] = MUSIC,
		["X-Origin"] = MUSIC,
		["User-Agent"] = DESKTOP,
		["X-Youtube-Client-Name"] = "67",
		["X-Youtube-Client-Version"] = MUSIC_VERSION,
	}
	if session.cookies then
		rotate(session)
		local sapisid = innertube.sapisid(session.cookies)
		if not sapisid then
			error("The cookies have no SAPISID, copy them while signed in")
		end
		local stamp = tostring(os.time())
		headers["Cookie"] = session.cookies
		headers["Authorization"] = "SAPISIDHASH " .. stamp .. "_" .. nari.sha1(stamp .. " " .. sapisid .. " " .. MUSIC)
		headers["X-Goog-AuthUser"] = "0"
	end
	local decoded, response = request(MUSIC .. "/youtubei/v1/" .. endpoint .. "?prettyPrint=false&alt=json" .. (query or ""), headers, body)
	if session.cookies then
		session.cookies = innertube.absorb(session.cookies, response.headers["set-cookie"])
	end
	local visitor = decoded.responseContext and decoded.responseContext.visitorData
	if visitor and visitor ~= "" then
		innertube.visitor = visitor
	end
	return decoded
end

function innertube.account(session)
	local response = innertube.music(session, "account/account_menu", {})
	local header = innertube.find(response, "activeAccountHeaderRenderer")[1]
	return header and text(header.accountName)
end

function innertube.song(renderer, album)
	local id = renderer.playlistItemData and renderer.playlistItemData.videoId
	if not id then
		local watch = innertube.find(renderer, "watchEndpoint")[1]
		id = watch and watch.videoId
	end
	if not id then
		return nil
	end
	local columns = renderer.flexColumns or {}
	local function column(index)
		local flex = columns[index] and columns[index].musicResponsiveListItemFlexColumnRenderer
		return flex and flex.text or {}
	end
	local artists, artist_ids = {}, {}
	local album_title, album_id = album and album.title or "", album and album.id or ""
	local duration = 0
	for index = 2, #columns do
		for _, run in ipairs(column(index).runs or {}) do
			local target, page = link(run)
			if ARTIST_PAGES[page] then
				table.insert(artists, run.text)
				table.insert(artist_ids, artist_id(target))
			elseif page == "MUSIC_PAGE_TYPE_ALBUM" then
				album_title, album_id = run.text, target
			elseif (run.text or ""):match("^%d+:%d%d$") then
				duration = clock(run.text)
			end
		end
	end
	for _, fixed in ipairs(renderer.fixedColumns or {}) do
		local value = text(fixed.musicResponsiveListItemFixedColumnRenderer.text)
		if value:match("^%d+:%d%d") then
			duration = clock(value)
		end
	end
	local live = is_live(renderer)
	if #artists == 0 and album then
		artists, artist_ids = { album.artist }, { album.artist_id }
	elseif #artists == 0 then
		local runs = column(2).runs or {}
		local plain = runs[live and #runs or 1]
		if plain and plain.text and not plain.text:match("^%d+:%d%d$") then
			artists = { plain.text }
		end
	end
	local title = text(column(1))
	return {
		id = id,
		title = title,
		sort_title = title:lower(),
		artist = table.concat(artists, ", "),
		artists = artists,
		artist_id = artist_ids[1] or "",
		album = album_title,
		album_id = album_id,
		duration = live and 0 or duration,
		live = live or nil,
		track_number = tonumber(text(renderer.index)) or 0,
		disc_number = 0,
		year = album and album.year or 0,
		genres = {},
		file_name = id .. ".m4a",
		thumbnail = thumbnail(renderer.thumbnail) ~= "" and thumbnail(renderer.thumbnail) or (album and album.thumbnail or ""),
	}
end

local function column(renderer, index)
	local columns = renderer.flexColumns or {}
	local flex = columns[index] and columns[index].musicResponsiveListItemFlexColumnRenderer
	return flex and flex.text or {}
end

local function playlist_of(renderer)
	local watch = innertube.find(renderer, "watchPlaylistEndpoint")[1]
	return watch and watch.playlistId or ""
end

function innertube.album(renderer)
	local id, page = link(renderer)
	if page ~= "MUSIC_PAGE_TYPE_ALBUM" then
		return nil
	end
	local kind, artists, ids, year = "album", {}, {}, 0
	local subtitle = renderer.subtitle or column(renderer, 2)
	for index, run in ipairs(subtitle.runs or {}) do
		local target, linked = link(run)
		if ARTIST_PAGES[linked] then
			table.insert(artists, run.text)
			table.insert(ids, artist_id(target))
		elseif (run.text or ""):match("^%d%d%d%d$") then
			year = tonumber(run.text)
		elseif index == 1 and run.text ~= " • " then
			kind = run.text:lower()
		end
	end
	return {
		id = id,
		title = text(renderer.title or column(renderer, 1)),
		artist = table.concat(artists, ", "),
		artist_id = ids[1] or "",
		year = year,
		release_type = kind,
		song_count = 0,
		duration = 0,
		playlist_id = playlist_of(renderer),
		thumbnail = thumbnail(renderer.thumbnailRenderer or renderer.thumbnail),
	}
end

function innertube.artist(renderer)
	local id, page = link(renderer)
	if not id or not ARTIST_PAGES[page] and not id:match("^MPLA") and not id:match("^UC") then
		return nil
	end
	local songs = text(renderer.subtitle or column(renderer, 2)):match("([%d,%.]+) songs?")
	return {
		id = artist_id(id),
		name = text(renderer.title or column(renderer, 1)),
		album_count = 0,
		song_count = songs and tonumber((songs:gsub("[,%.]", ""))) or 0,
		duration = 0,
		cover_album_id = artist_id(id),
		thumbnail = thumbnail(renderer.thumbnail or renderer.thumbnailRenderer),
	}
end

function innertube.video(renderer)
	local watch = renderer.navigationEndpoint and renderer.navigationEndpoint.watchEndpoint
	if not watch or not watch.videoId then
		return nil
	end
	local artists, ids = {}, {}
	for _, run in ipairs(renderer.subtitle and renderer.subtitle.runs or {}) do
		local target, page = link(run)
		if ARTIST_PAGES[page] then
			table.insert(artists, run.text)
			table.insert(ids, artist_id(target))
		end
	end
	local title = text(renderer.title)
	return {
		id = watch.videoId,
		title = title,
		sort_title = title:lower(),
		artist = table.concat(artists, ", "),
		artists = artists,
		artist_id = ids[1] or "",
		album = "",
		album_id = "",
		duration = 0,
		live = is_live(renderer) or nil,
		track_number = 0,
		disc_number = 0,
		year = 0,
		genres = {},
		file_name = watch.videoId .. ".m4a",
		thumbnail = thumbnail(renderer.thumbnailRenderer),
	}
end

local function continuation(response, seen)
	for _, command in ipairs(innertube.find(response, "continuationCommand")) do
		if command.token and not seen[command.token] then
			return command.token, true
		end
	end
	for _, data in ipairs(innertube.find(response, "nextContinuationData")) do
		if data.continuation and not seen[data.continuation] then
			return data.continuation, false
		end
	end
end

function innertube.browse_all(session, browse_id, key, parse, on_page)
	local items, known, seen = {}, {}, {}
	local response = innertube.music(session, "browse", { browseId = browse_id })
	for page = 1, MAX_PAGES do
		for _, renderer in ipairs(innertube.find(response, key)) do
			local item = parse(renderer)
			if item and not known[item.id] then
				known[item.id] = true
				table.insert(items, item)
			end
		end
		if on_page then
			on_page(page, #items)
		end
		local token, modern = continuation(response, seen)
		if not token then
			break
		end
		seen[token] = true
		if modern then
			response = innertube.music(session, "browse", { continuation = token })
		else
			response = innertube.music(session, "browse", {}, "&ctoken=" .. token .. "&continuation=" .. token .. "&type=next")
		end
	end
	return items
end

function innertube.album_page(session, id)
	local response = innertube.music(session, "browse", { browseId = id })
	local header = innertube.find(response, "musicResponsiveHeaderRenderer")[1] or innertube.find(response, "musicDetailHeaderRenderer")[1] or {}
	local album = { id = id, title = text(header.title), artist = "", artist_id = "", year = 0, release_type = "album", song_count = 0, duration = 0 }
	album.thumbnail = thumbnail(header.thumbnail)
	for _, run in ipairs(header.straplineTextOne and header.straplineTextOne.runs or {}) do
		local target, page = link(run)
		if ARTIST_PAGES[page] and album.artist_id == "" then
			album.artist, album.artist_id = run.text, artist_id(target)
		end
	end
	for index, run in ipairs(header.subtitle and header.subtitle.runs or {}) do
		local target, page = link(run)
		if (run.text or ""):match("^%d%d%d%d$") then
			album.year = tonumber(run.text)
		elseif ARTIST_PAGES[page] and album.artist_id == "" then
			album.artist, album.artist_id = run.text, artist_id(target)
		elseif index == 1 then
			album.release_type = (run.text or "album"):lower()
		end
	end
	local tracks = {}
	for _, renderer in ipairs(innertube.find(response, "musicResponsiveListItemRenderer")) do
		local track = innertube.song(renderer, album)
		if track then
			table.insert(tracks, track)
			album.duration = album.duration + track.duration
		end
	end
	album.tracks = tracks
	album.song_count = #tracks
	album.playlist_id = (innertube.find(response, "audioPlaylistId")[1]) or playlist_of(header)
	return album
end

function innertube.playlist(renderer)
	local id = link(renderer)
	if not id or not id:match("^VL") or id == "VLLM" or id == "VLSE" then
		return nil
	end
	local subtitle = text(renderer.subtitle)
	local songs = subtitle:match("([%d,%.]+) songs?") or subtitle:match("([%d,%.]+) tracks?")
	local playlist_id = id:sub(3)
	return {
		id = playlist_id,
		name = text(renderer.title),
		song_count = songs and tonumber((songs:gsub("[,%.]", ""))) or nil,
		duration = 0,
		modified = 0,
		cover_album_ids = { playlist_id },
		image = "",
		thumbnail = thumbnail(renderer.thumbnailRenderer),
	}
end

function innertube.playlist_tracks(session, id)
	local response = innertube.music(session, "browse", { browseId = "VL" .. id })
	local node = innertube.find(response, "musicPlaylistShelfRenderer")[1]
	local tracks, seen = {}, {}
	for _ = 1, MAX_PAGES do
		if not node then
			break
		end
		for _, renderer in ipairs(innertube.find(node, "musicResponsiveListItemRenderer")) do
			local track = innertube.song(renderer)
			if track then
				track.set_video_id = renderer.playlistItemData and renderer.playlistItemData.playlistSetVideoId or ""
				table.insert(tracks, track)
			end
		end
		local token, modern = continuation(node, seen)
		if not token then
			break
		end
		seen[token] = true
		if modern then
			local answer = innertube.music(session, "browse", { continuation = token })
			node = innertube.find(answer, "appendContinuationItemsAction")[1]
		else
			local answer = innertube.music(session, "browse", {}, "&ctoken=" .. token .. "&continuation=" .. token .. "&type=next")
			node = innertube.find(answer, "musicPlaylistShelfContinuation")[1]
		end
	end
	return tracks
end

function innertube.create_playlist(session, name)
	local response = innertube.music(session, "playlist/create", { title = name, description = "", privacyStatus = "PRIVATE" })
	if not response.playlistId then
		error("YouTube Music didn't create the playlist")
	end
	return response.playlistId
end

function innertube.delete_playlist(session, id)
	innertube.music(session, "playlist/delete", { playlistId = id })
end

function innertube.edit_playlist(session, id, actions)
	local response = innertube.music(session, "browse/edit_playlist", { playlistId = id, actions = actions })
	if response.status ~= "STATUS_SUCCEEDED" then
		error("YouTube Music didn't save the playlist change")
	end
	local added = {}
	for _, result in ipairs(innertube.find(response, "playlistEditVideoAddedResultData")) do
		if result.videoId and result.setVideoId then
			added[result.videoId] = result.setVideoId
		end
	end
	return added
end

local function vision_player(id, visitor)
	local client = {
		hl = "en",
		gl = "US",
		clientName = "VISIONOS",
		clientVersion = "1.02",
		userAgent = VISION,
		utcOffsetMinutes = 0,
		deviceMake = "Apple",
		deviceModel = "RealityDevice17,1",
		osName = "visionOS",
		osVersion = "26.5.23O471",
		visitorData = visitor,
	}
	return request(YOUTUBE .. "/youtubei/v1/player?prettyPrint=false&alt=json", {
		["Content-Type"] = "application/json",
		["Origin"] = YOUTUBE,
		["User-Agent"] = VISION,
		["X-Youtube-Client-Name"] = "101",
		["X-Youtube-Client-Version"] = "1.02",
	}, {
		videoId = id,
		contentCheckOk = true,
		racyCheckOk = true,
		playbackContext = { contentPlaybackContext = { html5Preference = "HTML5_PREF_WANTS" } },
		context = { client = client },
	})
end

local function player(id)
	local response = vision_player(id)
	local status = response.playabilityStatus or {}
	if status.status == "LOGIN_REQUIRED" and response.responseContext and response.responseContext.visitorData then
		response = vision_player(id, response.responseContext.visitorData)
		status = response.playabilityStatus or {}
	end
	if status.status ~= "OK" then
		error(id .. " can't be played: " .. tostring(status.reason or status.status))
	end
	return response
end

function innertube.pick(formats, quality)
	local limit = BITRATES[quality] and BITRATES[quality] * 1100 or math.huge
	local best, lowest
	for _, format in ipairs(formats) do
		if format.url and (format.mimeType or ""):match("^audio/") then
			local rate = format.averageBitrate or format.bitrate or 0
			if not lowest or rate < lowest.rate then
				lowest = { url = format.url, rate = rate }
			end
			if rate <= limit and (not best or rate > best.rate) then
				best = { url = format.url, rate = rate }
			end
		end
	end
	return (best or lowest or {}).url
end

local function live_audio(master, quality)
	local response, problem = nari.http({ url = master })
	if not response or response.status ~= 200 then
		error("the live stream couldn't be opened: " .. tostring(problem or response.status))
	end
	local codecs, fallback = {}, nil
	for codec, group in response.body:gmatch('#EXT%-X%-STREAM%-INF:[^\n]-CODECS="[^"]-(mp4a%.40%.%d)[^\n]-AUDIO="([^"]+)"') do
		codecs[codec] = group
	end
	local wanted = codecs[quality == "low" and "mp4a.40.5" or "mp4a.40.2"]
	for line in response.body:gmatch("#EXT%-X%-MEDIA:[^\n]+") do
		local uri, group = line:match('URI="([^"]+)"'), line:match('GROUP%-ID="([^"]+)"')
		if uri and line:find("TYPE=AUDIO", 1, true) then
			if group == wanted then
				return uri
			end
			fallback = fallback or uri
		end
	end
	return fallback or master
end

function innertube.stream(id, quality)
	local response = player(id)
	local master = response.streamingData and response.streamingData.hlsManifestUrl
	if master and response.videoDetails and response.videoDetails.isLive then
		return live_audio(master, quality)
	end
	local url = innertube.pick(response.streamingData and response.streamingData.adaptiveFormats or {}, quality)
	if not url then
		error(id .. " has no direct audio stream")
	end
	return url
end

function innertube.song_details(id)
	local details = player(id).videoDetails or {}
	local name = (details.author or ""):gsub(" %- Topic$", "")
	return {
		id = id,
		title = details.title or "",
		sort_title = (details.title or ""):lower(),
		artist = name,
		artists = { name },
		artist_id = details.channelId or "",
		album = "",
		album_id = "",
		duration = (tonumber(details.lengthSeconds) or 0) * 1000,
		track_number = 0,
		disc_number = 0,
		year = 0,
		genres = {},
		file_name = id .. ".m4a",
		thumbnail = thumbnail(details.thumbnail),
	}
end

function innertube.card(content)
	if content.musicResponsiveListItemRenderer then
		local song = innertube.song(content.musicResponsiveListItemRenderer)
		return song and "tracks", song
	end
	local renderer = content.musicTwoRowItemRenderer
	if not renderer then
		return nil
	end
	local song = innertube.video(renderer)
	if song then
		return "tracks", song
	end
	local _, page = link(renderer)
	if page == "MUSIC_PAGE_TYPE_ALBUM" then
		return "albums", innertube.album(renderer)
	elseif ARTIST_PAGES[page] then
		return "artists", innertube.artist(renderer)
	elseif page == "MUSIC_PAGE_TYPE_PLAYLIST" then
		return "playlists", innertube.playlist(renderer)
	end
end

local function shelf_title(shelf)
	return text(innertube.find(shelf.header or {}, "title")[1])
end

local function shelves(response, sections)
	for _, shelf in ipairs(innertube.find(response, "musicCarouselShelfRenderer")) do
		local groups, best = {}, nil
		for _, content in ipairs(shelf.contents or {}) do
			local kind, item = innertube.card(content)
			if kind and item then
				groups[kind] = groups[kind] or {}
				table.insert(groups[kind], item)
				if not best or #groups[kind] > #groups[best] then
					best = kind
				end
			end
		end
		if best then
			local quick = best == "tracks" and shelf.contents[1].musicResponsiveListItemRenderer ~= nil
			table.insert(sections, { title = shelf_title(shelf), kind = quick and "quick_picks" or best, items = groups[best] })
		end
	end
end

function innertube.home(session)
	local sections, seen = {}, {}
	local response = innertube.music(session, "browse", { browseId = "FEmusic_home" })
	for _ = 1, HOME_PAGES do
		shelves(response, sections)
		local token, modern = continuation(response, seen)
		if not token then
			break
		end
		seen[token] = true
		if modern then
			response = innertube.music(session, "browse", { continuation = token })
		else
			response = innertube.music(session, "browse", {}, "&ctoken=" .. token .. "&continuation=" .. token .. "&type=next")
		end
	end
	return sections
end

function innertube.lives(session, query)
	local found = {}
	local response = innertube.music(session, "search", { query = query, params = VIDEOS })
	for _, renderer in ipairs(innertube.find(response, "musicResponsiveListItemRenderer")) do
		local song = innertube.song(renderer)
		if song and song.live then
			table.insert(found, song)
		end
	end
	return found
end

function innertube.search(session, query)
	local found = {}
	for kind, params in pairs(SEARCH) do
		local response = innertube.music(session, "search", { query = query, params = params })
		found[kind] = {}
		for _, renderer in ipairs(innertube.find(response, "musicResponsiveListItemRenderer")) do
			local item = kind == "tracks" and innertube.song(renderer) or kind == "albums" and innertube.album(renderer) or innertube.artist(renderer)
			if item and (kind ~= "albums" or #found[kind] < SEARCH_ALBUMS) then
				table.insert(found[kind], item)
			end
		end
	end
	local ok, lives = pcall(innertube.lives, session, query)
	for position, song in ipairs(ok and lives or {}) do
		table.insert(found.tracks, position, song)
	end
	return found
end

local function audience(label)
	local number, unit = label:match("([%d%.,]+)%s*([KMB]?)")
	if not number then
		return 0
	end
	local value = tonumber((number:gsub(",", ""))) or 0
	return math.floor(value * (({ K = 1e3, M = 1e6, B = 1e9 })[unit] or 1))
end

function innertube.artist_page(session, id)
	local response = innertube.music(session, "browse", { browseId = id })
	local header = innertube.find(response, "musicImmersiveHeaderRenderer")[1] or innertube.find(response, "musicVisualHeaderRenderer")[1] or {}
	local artist = { id = id, name = text(header.title), cover_album_id = id, thumbnail = thumbnail(header.thumbnail), albums = {}, tracks = {}, duration = 0 }
	local shelf = innertube.find(response, "musicShelfRenderer")[1]
	local more = shelf and shelf.bottomEndpoint and shelf.bottomEndpoint.browseEndpoint
	if more and more.browseId:match("^VL") then
		local ok, tracks = pcall(innertube.playlist_tracks, session, more.browseId:sub(3))
		artist.tracks = ok and tracks or {}
	end
	if #artist.tracks == 0 and shelf then
		for _, renderer in ipairs(innertube.find(shelf, "musicResponsiveListItemRenderer")) do
			table.insert(artist.tracks, innertube.song(renderer))
		end
	end
	artist.top_tracks = artist.tracks
	artist.bio = text(header.description)
	if artist.bio == "" then
		artist.bio = text((innertube.find(response, "musicDescriptionShelfRenderer")[1] or {}).description)
	end
	artist.listeners = audience(text(header.monthlyListenerCount))
	artist.sections = {}
	local known = {}
	for position, carousel in ipairs(innertube.find(response, "musicCarouselShelfRenderer")) do
		local title = shelf_title(carousel)
		local groups = {}
		for _, content in ipairs(carousel.contents or {}) do
			local kind, item = innertube.card(content)
			if kind and item then
				groups[kind] = groups[kind] or {}
				table.insert(groups[kind], item)
			end
		end
		for _, album in ipairs(groups.albums or {}) do
			if not known[album.id] then
				known[album.id] = true
				album.artist = album.artist ~= "" and album.artist or artist.name
				album.artist_id = album.artist_id ~= "" and album.artist_id or id
				if title:lower():match("single") then
					album.release_type = "single"
				elseif title:lower():match("featured") or title:lower():match("appears") then
					album.release_type = "appears_on"
				end
				table.insert(artist.albums, album)
			end
		end
		if groups.artists and not artist.related then
			artist.related = groups.artists
		end
		for _, kind in ipairs({ "tracks", "playlists" }) do
			if groups[kind] then
				table.insert(artist.sections, { title = title, kind = kind, items = groups[kind], order = 44 + position / 100 })
			end
		end
	end
	for _, track in ipairs(artist.tracks) do
		artist.duration = artist.duration + track.duration
	end
	artist.album_count = #artist.albums
	artist.song_count = #artist.tracks
	return artist
end

function innertube.like(session, target, on)
	innertube.music(session, on and "like/like" or "like/removelike", { target = target })
end

function innertube.follow(session, id, on)
	innertube.music(session, on and "subscription/subscribe" or "subscription/unsubscribe", { channelIds = { id } })
end

return innertube
