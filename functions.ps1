
$config = (Get-Content "config.json" | ConvertFrom-Json)

$googleai_key = $config.googleai_key

class TrackHistory {
	[int]$id
	[int]$user_id
	[string]$song_id
	[string]$song_name
	[string]$album_name
	[string]$artists
	[string]$played_at
	[bool]$skipped
	[int]$duration_ms
	[int]$progress_ms

	TrackHistory(
		[Object] $props
	) {
		$this.id = $props.id
		$this.user_id = $props.user_id
		$this.song_id = $props.song_id
		$this.song_name = $props.song_name
		$this.album_name = $props.album_name
		$this.artists = $props.artists
		$this.played_at = $props.played_at
		$this.skipped = $props.skipped
		$this.duration_ms = $props.duration_ms
		$this.progress_ms = $props.progress_ms
	}
}

class SpotifyAPI {
	[string]$access_token
	[string]$refresh_token
	[string]$client_id
	[string]$client_secret
	[string]$playlist_id
	[int]$user_id
	[int]$current_trackhistory_id
	[int]$current_song_id

	SpotifyAPI(
		[int]$userId
	) {
		$cred = New-Object System.Management.Automation.PSCredential($global:config.database.username, (ConvertTo-SecureString $global:config.database.password -AsPlainText))
		Open-MySqlConnection -Server $global:config.database.host -Port $global:config.database.port -Database $global:config.database.database -Credential $cred -ConnectionName "spotifyai"
		$query = "SELECT * FROM users where id = $userId"
		$data = Invoke-SqlQuery -ConnectionName "spotifyai" -Query $query
		Close-SqlConnection -ConnectionName "spotifyai"
		
		$this.access_token = $data.access_token
		$this.refresh_token = $data.refresh_token
		$this.client_id = $global:config.client_id
		$this.client_secret = $global:config.client_secret
		$this.playlist_id = $data.playlist_id
		$this.user_id = $userId

	}

	[Object[]] QuerySQL($query) {
		$cred = New-Object System.Management.Automation.PSCredential($global:config.database.username, (ConvertTo-SecureString $global:config.database.password -AsPlainText))
		Open-MySqlConnection -Server $global:config.database.host -Port $global:config.database.port -Database $global:config.database.database -Credential $cred -ConnectionName "spotifyai"
		$resp = Invoke-SqlQuery -ConnectionName "spotifyai" -Query $query
		Close-SqlConnection -ConnectionName "spotifyai"
		return $resp
	}

	[void] UpdateSQL($query) {
		$cred = New-Object System.Management.Automation.PSCredential($global:config.database.username, (ConvertTo-SecureString $global:config.database.password -AsPlainText))
		Open-MySqlConnection -Server $global:config.database.host -Port $global:config.database.port -Database $global:config.database.database -Credential $cred -ConnectionName "spotifyai"
		Invoke-SqlUpdate -ConnectionName "spotifyai" -Query $query | Out-Null
		Close-SqlConnection -ConnectionName "spotifyai"
	}

	[void] SaveDBAccessToken() {
		$query = "UPDATE users SET access_token = '$($this.access_token)' WHERE id = $($this.user_id)"
		$this.UpdateSQL($query)
	}

	[Object[]] GetTrackHistory() {
		$query = "SELECT * FROM track_history WHERE user_id = $($this.user_id)"
		$data = $this.QuerySQL($query)
		return $data
	}

	[Object] GetLastTrackHistory() {
		$query = "SELECT * FROM track_history WHERE user_id = $($this.user_id) ORDER BY played_at DESC LIMIT 1"
		$data = $this.QuerySQL($query)
		return $data
	}

	[void] InsertTrackHistory([TrackHistory] $track) {
		$query = "INSERT INTO track_history (
			user_id,
			song_id,
			song_name,
			album_name,
			artists,
			played_at,
			progress_ms,
			duration_ms,
			skipped
		) VALUES (
			$($track.user_id),
			'$($track.song_id)',
			'$($track.song_name.replace("'","''").replace('"','\"'))',
			'$($track.album_name.replace("'","''").replace('"','\"'))',
			'$($track.artists.replace("'","''").replace('"','\"'))',
			'$(Get-Date $track.played_at -Format "yyyy-MM-dd HH:mm:ss")',
			$($track.progress_ms),
			$($track.duration_ms),
			$($track.skipped ? 1 : 0)
		)"
		$this.UpdateSQL($query)
	}

	[void] UpdateTrackHistory([TrackHistory] $track) {
		$query = "UPDATE track_history SET
			skipped = $($track.skipped ? 1 : 0),
			progress_ms = $($track.progress_ms)
		WHERE id = $($track.id)"
		$this.UpdateSQL($query)
	}

	[void] InsertPlaylistChange($summary) {
		$query = "INSERT INTO playlist_changes (
			user_id,
			changed_at,
			summary
		) VALUES (
			$($this.user_id),
			'$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")',
			'$($summary.replace("'","''").replace('"','\"'))'
		)"
		$this.UpdateSQL($query)
	}

	[void] RefreshToken() {
		$url = "https://accounts.spotify.com/api/token"
		$headers = @{
			"Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$($this.client_id):$($this.client_secret)"))
			"Content-Type"  = "application/x-www-form-urlencoded"
		}
		$body = @{
			"grant_type"    = "refresh_token"
			"refresh_token" = $this.refresh_token
		}
		$response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body
		$this.access_token = $response.access_token
		$this.SaveDBAccessToken()
	}

	[Object]Invoke($Endpoint, $Method) {
		return $this.Invoke($Endpoint, $Method, $null)
	}
	
	[Object]Invoke($Endpoint, $Method, $Data) {
		$url = "https://api.spotify.com/v1$($Endpoint)"
		$headers = @{
			"Authorization" = "Bearer " + $this.access_token
		}

		try {
			if ($Data -eq $null) {
				$response = Invoke-RestMethod -Uri $url -Method $Method -Headers $headers
			}
			else {
				$response = Invoke-RestMethod -Uri $url -Method $Method -Headers $headers -Body ($Data | ConvertTo-Json) -ContentType "application/json"
			}
		}
		catch {
			Write-Error $_
			$response = $_.Exception.Response
		}

		#Write-Host $url
		if ($response.StatusCode -eq "Unauthorized") {
			Write-Host "Refreshing token"
			$this.RefreshToken()
			Start-Sleep 2
			return $this.Invoke($Endpoint, $Method, $Data)
		}
		else {
			return $response
		}
	}
}

function Ask-AI($textArray) {

	$parts = @()

	foreach ($item in $textArray) {
		$parts += @{
			"text" = $item
		}
	}

	$body = @{
		"contents" = @{
			"parts" = $parts
		}
	}
	
	$headers = @{
		"Content-Type" = "application/json"
	}
	
	$aiResp = Invoke-RestMethod -Uri "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$($global:googleai_key)" -Headers $headers -Method Post -Body ($body | ConvertTo-Json -Depth 10)

	return $aiResp.candidates.content.parts[0].text
}
