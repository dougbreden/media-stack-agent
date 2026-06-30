The user wants to search for specific content. $ARGUMENTS is the movie or TV series name (and optionally a season number, e.g. "Show Name S1" or "Movie Title").

Steps:
1. Search Sonarr for the series name: GET http://localhost:8989/api/v3/series?apikey=<sonarr-key>
   Filter by title match. If found, show: series ID, title, monitored status, episode counts per season, which seasons have missing episodes.

2. If not found in Sonarr, search Radarr: GET http://localhost:7878/api/v3/movie?apikey=<radarr-key>
   Filter by title match. Show monitored status and whether a file exists.

3. If found and has missing episodes/files:
   - Ask if the user wants to trigger a search (SeasonSearch for TV, MoviesSearch for movies)
   - If a season number was specified, only search that season

4. If NOT found in either app (not added yet):
   - Tell the user to add it via Jellyseerr (http://localhost:5055) or directly in Sonarr/Radarr
   - Note that Nyaa.si is required for SubsPlease/Erai-raws releases (they only publish there)

5. To investigate why a specific episode has no results, use the interactive release search:
   GET http://localhost:8989/api/v3/release?apikey=<sonarr-key>&episodeId=<id>
   Sort by customFormatScore descending, show top 10 with score and rejection status.

Always use PowerShell's Invoke-RestMethod for API calls.
