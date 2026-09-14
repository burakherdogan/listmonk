// Package bot detects non-human requests on the public tracking endpoints
// (the open-tracking pixel and link redirects).
//
// Corporate mail security products rewrite and pre-fetch every URL in an
// e-mail before the recipient ever sees it. Microsoft Defender for Office 365
// (Safe Links), Proofpoint URL Defense, Mimecast, Barracuda and friends all do
// this, which is why a single subscriber can appear to have clicked 289 times
// across the 16 links of one campaign. Those hits are machine traffic and must
// not be counted as engagement.
//
// Detection here is deliberately conservative: it only matches user agents
// that cannot plausibly belong to a human reading mail in a browser. Scanners
// that spoof a real browser UA are caught downstream by the burst heuristic in
// the SQL insert instead.
package bot

import (
	"regexp"
	"strings"
)

const (
	// BurstClickLimit is how many clicks a single subscriber may register on one
	// campaign within BurstWindowSecs before further clicks are treated as
	// machine traffic. A scanner walks every link in a message in a couple of
	// seconds; a human opening links in tabs stays well under this.
	BurstClickLimit = 10

	// BurstWindowSecs is the look-back window, in seconds, for BurstClickLimit.
	BurstWindowSecs = 30
)

// scannerUA matches user agents belonging to mail security scanners, link
// pre-fetchers, mailbox image proxies and generic HTTP libraries. Anchoring is
// avoided on purpose because these tokens usually appear mid-string, often
// appended to an otherwise browser-like UA.
var scannerUA = regexp.MustCompile(strings.Join([]string{
	// Mail security gateways and link-rewriting scanners.
	`proofpoint`,
	`urldefense`,
	`mimecast`,
	`barracuda`,
	`ironport`,
	`forcepoint`,
	`websense`,
	`bluecoat`,
	`symantec`,
	`sophos`,
	`mcafee`,
	`trendmicro`,
	`fireeye`,
	`zscaler`,
	`cloudmark`,
	`messagelabs`,
	`safelinks`,

	// Mailbox image proxies that fetch the tracking pixel on the user's behalf.
	// A hit from these means "the message was rendered", but they also pre-fetch
	// aggressively, so they are treated as machine traffic.
	`googleimageproxy`,
	`yahoomailproxy`,

	// Generic crawlers and scrapers.
	`bot\b`,
	`\bbots\b`,
	`crawler`,
	`spider`,
	`slurp`,
	`archiver`,
	`scanner`,
	`monitor`,
	`validator`,
	`fetcher`,
	`uripreview`,
	`linkpreview`,

	// HTTP client libraries and headless browsers. No human clicks a newsletter
	// link with curl.
	`curl/`,
	`wget`,
	`libwww`,
	`python-requests`,
	`python-urllib`,
	`aiohttp`,
	`httpx`,
	`go-http-client`,
	`java/`,
	`okhttp`,
	`axios`,
	`node-fetch`,
	`guzzle`,
	`lwp::`,
	`phantomjs`,
	`headlesschrome`,
	`puppeteer`,
	`playwright`,
	`selenium`,
	`apache-httpclient`,
	`restsharp`,
	`postmanruntime`,
}, "|"))

// IsBot reports whether a tracking hit with the given request headers came from
// an automated client rather than a human.
//
// ua is the User-Agent header. secPurpose and xPurpose are the `Sec-Purpose`
// (and legacy `X-Purpose` / `Purpose`) headers, which browsers and proxies set
// to `prefetch` when speculatively loading a URL the user has not activated.
func IsBot(ua, secPurpose, xPurpose string) bool {
	// An empty user agent on a public tracking endpoint is never a real browser.
	if strings.TrimSpace(ua) == "" {
		return true
	}

	// Speculative pre-fetches are explicitly not user-initiated.
	if isPrefetch(secPurpose) || isPrefetch(xPurpose) {
		return true
	}

	return scannerUA.MatchString(strings.ToLower(ua))
}

// isPrefetch reports whether a Purpose-style header marks the request as
// speculative rather than user-initiated.
func isPrefetch(v string) bool {
	v = strings.ToLower(v)
	return strings.Contains(v, "prefetch") || strings.Contains(v, "preview")
}
