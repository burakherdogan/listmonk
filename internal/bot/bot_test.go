package bot

import "testing"

func TestIsBotAllowsRealBrowsers(t *testing.T) {
	uas := []string{
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.2210.91",
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2.1 Safari/605.1.15",
		"Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
		"Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Mobile Safari/537.36",
		"Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0",
		// Consumer antivirus vendors ship Chromium forks that humans browse with.
		// Matching on the vendor name alone would discard genuine engagement.
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36 Avast/119.0.24136.106",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36 SamsungBrowser/23.0",
	}

	for _, ua := range uas {
		if IsBot(ua, "", "") {
			t.Errorf("real browser flagged as bot: %s", ua)
		}
	}
}

func TestIsBotDetectsScannersAndClients(t *testing.T) {
	uas := []string{
		"Mozilla/5.0 (compatible; ProofPoint URL Defense)",
		"Mimecast Link Protection",
		"Mozilla/5.0 (compatible; BarracudaSentinel/1.0)",
		"Cisco IronPort Email Security",
		"Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
		"Mozilla/5.0 (Windows NT 5.1; rv:11.0) Gecko Firefox/11.0 (via ggpht.com GoogleImageProxy)",
		"curl/8.4.0",
		"Wget/1.21.4",
		"python-requests/2.31.0",
		"Go-http-client/1.1",
		"Java/17.0.9",
		"Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/120.0.0.0 Safari/537.36",
		"PostmanRuntime/7.36.0",
	}

	for _, ua := range uas {
		if !IsBot(ua, "", "") {
			t.Errorf("automated client not flagged: %s", ua)
		}
	}
}

func TestIsBotFlagsEmptyUserAgent(t *testing.T) {
	if !IsBot("", "", "") {
		t.Error("empty user agent should be treated as a bot")
	}
	if !IsBot("   ", "", "") {
		t.Error("blank user agent should be treated as a bot")
	}
}

func TestIsBotFlagsPrefetch(t *testing.T) {
	chrome := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

	if !IsBot(chrome, "prefetch;prerender", "") {
		t.Error("Sec-Purpose prefetch should be treated as a bot")
	}
	if !IsBot(chrome, "", "preview") {
		t.Error("X-Purpose preview should be treated as a bot")
	}
	if IsBot(chrome, "", "") {
		t.Error("absent purpose headers should not flag a real browser")
	}
}
