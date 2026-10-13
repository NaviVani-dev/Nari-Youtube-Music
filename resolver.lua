local innertube = require("innertube")

nari.resolver("ytmusic", function(raw)
	local id, quality = raw:match("^([^?]*)%??quality=(%a*)")
	return innertube.stream(id or raw, quality)
end)
