The user wants to search for specific content. $ARGUMENTS is the movie or TV series name (and optionally a season number, e.g. "a show S1" or "a show").

Steps:
1. Search Sonarr for the series name: GET http://localhost:8989/api/v3/series?apikey=ee46bcbfbdfe48e4b7863db24f6ecb25
   Filter by title match. If found, show: series ID, title, monitored status, episode counts per season, which seasons have missing episodes.

2. If not found in Sonarr, search Radarr: GET http://localhost:7878/api/v3/movie?apikey=ffe2d5d77df04128b2027ea05aa4bc86
   Filter by title match. Show monitored status and whether a file exists.

3. If found and has missing episodes/files:
   - Ask if the user wants to trigger a search (SeasonSearch for TV, MoviesSearch for movies)
   - If a season number was specified, only search that season

4. If NOT found in either app (not added yet):
   - Tell the user to add it via Jellyseerr (http://localhost:5055) or directly in Sonarr/Radarr
   - Note that Nyaa.si is required for content (SubsPlease/Erai-raws only publish there)

5. To investigate why a specific episode has no results, use the interactive release search:
   GET http://localhost:8989/api/v3/release?apikey=ee46bcbfbdfe48e4b7863db24f6ecb25&episodeId=<id>
   Sort by customFormatScore descending, show top 10 with score and rejection status.

Always use PowerShell's Invoke-RestMethod for API calls.
