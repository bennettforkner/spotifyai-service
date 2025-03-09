
$config = (Get-Content config.json | ConvertFrom-Json)

Start-Transcript $config.transcript_path -Append

Write-Host "Starting..."

#Install-Module SimplySql -Confirm:$false -Force

. "$($config.service_root)/functions.ps1"

$secondsInterval = 10
$userId = 1



$spotify = [SpotifyAPI]::new($userId)
$playlistId = $spotify.playlist_id



$songHistory = $spotify.GetTrackHistory()
if ($songHistory.GetType().Name -eq "PSCustomObject") {
	$songHistory = @($songHistory)
}

$firstRun = $true

$index = 0

while ($true) {

	$lastSong = $songHistory[-1]

	$player = $spotify.Invoke("/me/player","GET")

	if (!$player -OR $player.is_playing -eq $false) {
		Write-Host "Not playing"
		Start-Sleep ($secondsInterval * 5)
		continue
	}

	if ($player.context.type -eq 'playlist' -AND $player.context.uri -like "*$($playlistId)") {
		# Write-Host "Playling from AI playlist"
		Start-Sleep $secondsInterval
		continue
	} else {
		$index++
	}
	Write-Host "$index"

	if ($player.item.id -ne $lastSong.song_id) {
		$trackHistoryRecord = [TrackHistory]::new(@{
			"song_id"=$player.item.id
			"user_id"=$userId
			"song_name"=$player.item.name
			"artists"=$player.item.artists.name -join " & "
			"album_name"=$player.item.album.name
			"played_at"=[DateTime]::Now.AddMilliseconds(0 - $player.progress_ms)
			"progress_ms"=$player.progress_ms
			"duration_ms"=$player.item.duration_ms
			"skipped"=$false
		})

		$spotify.InsertTrackHistory($trackHistoryRecord)
		$songHistory += $spotify.GetLastTrackHistory()

		if (($lastSong.duration_ms - $lastSong.progress_ms -gt ($secondsInterval * 3 * 1000)) -AND !$firstRun) {
			$lastSong.skipped = $true
			$spotify.UpdateTrackHistory($lastSong)
		}

	} else {
		$lastSong.progress_ms = $player.progress_ms
		$spotify.UpdateTrackHistory($lastSong)
	}
	
	if ($index % 10 -eq 0) {

		$text = @(
			"You are a bot whose job is to recommend music to users based on their recent listening history. You will be given a list of songs that have been played in JSON format and you should give 20-30 recommendations for names of songs that should be added to a playlist of similar music. Also place more value on more recently-played songs and devalue songs that have been skipped. You should prefer to switch artists rather than repeating the same artist. You should not recommend the same song multiple times. You should respond with a JSON object called recommendations that has an a name key for the name of the suggested song, an artist key for the artist's name, and a message key explaining why the song was suggested. There should also be a JSON property for the description for the collection of songs to be added to the playlist limited to 120 characters max called playlist_description.",
			"queue history in json: " + ($songHistory | Where-Object {$_.played_at -gt (Get-Date).AddHours(-1)} | Select-Object name, album, artists, skipped, played_at -Last 20 | ConvertTo-Json)
		)

		$aiResp = Ask-AI $text

		$aiResp = $aiResp.replace("``````json", "").replace("``````", "").trim() | ConvertFrom-Json

		$recommendations = $aiResp.recommendations

		$urisToAdd = @()
		foreach ($recommendation in $recommendations) {
			$resp = $spotify.Invoke("/search?type=track&q=$($recommendation.name.replace(" ", "%20"))", "GET")
			$urisToAdd += $resp.tracks.items[0].uri
		}

		# delete all songs from playlist
		$currentPlaylistItems = $spotify.Invoke("/playlists/$playlistId/tracks", "GET")
		$currentPlaylistItems = $currentPlaylistItems.items.track | Select-Object uri
		$spotify.Invoke("/playlists/$playlistId/tracks", "DELETE", @{
			"tracks"=$currentPlaylistItems
		}) | Out-Null

		# add all songs to playlist
		$spotify.Invoke("/playlists/$playlistId/tracks?uris=$($urisToAdd -join ",")", "POST") | Out-Null

		$spotify.Invoke("/playlists/$playlistId", "PUT", @{
			"description"=$aiResp.playlist_description
		}) | Out-Null

	}

	Start-Sleep $secondsInterval
	$firstRun = $false
}

Stop-Transcript
