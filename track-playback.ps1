
$config = (Get-Content config.json | ConvertFrom-Json)

Start-Transcript $config.transcript_path -Append

Write-Host "Starting..."

#Install-Module SimplySql -Confirm:$false -Force

. "$($config.service_root)/functions.ps1"

$secondsInterval = $config.playback_check_seconds
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

	$isPlayingAIPlaylist = ($player.context.type -eq 'playlist' -AND $player.context.uri -like "*$($playlistId)")
	
	$index++
	#Write-Host "$index"

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
	
	if (($index % $config.playlist_rebuild_runs) -eq 0 -AND !$isPlayingAIPlaylist) {

		Write-Host "Rebuilding AI Playlist..."

		$currentPlaylistItems = $spotify.Invoke("/playlists/$playlistId/tracks", "GET")
		$currentPlaylistItems = $currentPlaylistItems.items | Select-Object added_at,
			@{E={$_.track.uri};N="uri"},
			@{E={$_.track.name};N="name"},
			@{E={$_.track.artists.name -join " & "};N="artists"},
			@{E={$_.track.album.name};N="album"}

		$currentPlaylist = $spotify.Invoke("/playlists/$playlistId", "GET")

		$text = @(
			"You are a bot whose job is to recommend music to users based on their recent listening history.
			
			You will be given a list of songs that have been played in JSON format and you should give recommendations for names of songs that should be added to a playlist of similar music. Also place more value on the vibes of more recently-played songs and devalue songs that have been skipped. Recently played songs should not show up in the playlist. You should prefer to switch artists rather than repeating the same artist. You should not recommend the same song multiple times. The playlist should always have 20-30 songs. Do not suggest changes if there are no items in the song history. You are running every few minutes, so don't feel the need to make a whole lot of changes all the time.

			You will also be given the record of the current songs in the recommendations playlist. You should respond with a list of songs to remove, if any, and a list of songs to add. Pay attention to the added_at field as songs shouldn't stay on the playlist for too long.
			
			You should respond with a JSON array called 'recommended_additions' and one called 'recommended_removals'. Each should have an a 'name' key for the name of the suggested song and an 'artist' key for the artist's name. The recommended_removals array objects should also have an 'uri' property with the spotify uri for that song. If the playlist is good as-is, there may be no need to add or remove songs.
			
			There should also be a JSON property for the description for the collection of songs in the playlist limited to 120 characters max called 'playlist_description'. This description should be unique and fun to match the vibes of the songs. You will be provided the current playlist description and will determine whether or not it should change. If so, return a new playlist_description, otherwise, return the same one as provided.",
			"queue history in json: " + ($songHistory | Where-Object {$_.played_at -gt (Get-Date).AddHours(-2)} | Select-Object name, album, artists, skipped, played_at -Last 20 | ConvertTo-Json),
			"current playlist in json: " + ($currentPlaylistItems | ConvertTo-Json),
			"current playlist description: " + $currentPlaylist.description
		)

		$aiResp = Ask-AI $text

		$aiResp = $aiResp.replace("``````json", "").replace("``````", "").trim() | ConvertFrom-Json

		$recommendations = $aiResp.recommended_additions
		$removals = $aiResp.recommended_removals

		

		$summary = "Added $($recommendations.Count) songs and removed $($removals.Count) songs.`nDescription: $($aiResp.playlist_description)`n`nAdded:`n"
		foreach ($recommendation in $recommendations) {
			$summary += "`t$($recommendation.name)`n"
		}

		$summary += "`n`nRemovals:`n"
		foreach ($removal in $removals) {
			$summary += "`t$($removal.name)`n"
		}

		$spotify.InsertPlaylistChange($summary)

		$urisToAdd = @()
		foreach ($recommendation in $recommendations) {
			$resp = $spotify.Invoke("/search?type=track&q=$($recommendation.name.replace(" ", "%20"))", "GET")
			$urisToAdd += $resp.tracks.items[0].uri
		}

		if ($removals.Count -gt 0) {
			# delete all songs from playlist
			$resp = $spotify.Invoke("/playlists/$playlistId/tracks", "DELETE", @{
				"tracks"=($removals | Select-Object uri)
			})
		}

		# add all songs to playlist
		$resp = $spotify.Invoke("/playlists/$playlistId/tracks?uris=$($urisToAdd -join ",")", "POST")

		$resp = $spotify.Invoke("/playlists/$playlistId", "PUT", @{
			"description"=$aiResp.playlist_description
		})

	}

	Start-Sleep $secondsInterval
	$firstRun = $false
}

Stop-Transcript
