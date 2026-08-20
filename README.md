# UmamiAnalytics

UmamiAnalytics integrates Umami page-view analytics with MediaWiki.

All MediaWiki-specific tracking logic is contained in the extension.
`LocalSettings.php` only contains deployment configuration.

## Features

- centrally deployed MediaWiki extension;
- extension-owned ResourceLoader module;
- no Gadget or editable wiki JavaScript;
- canonical MediaWiki URL sent to Umami;
- MediaWiki display title sent as plain text;
- Umami automatic page-view tracking disabled;
- exactly one controlled page view per eligible document load;
- configurable namespace selection;
- old revisions and diffs excluded by default;
- special pages and missing pages excluded;
- no MediaWiki user name or user ID sent;
- no MediaWiki page ID sent;
- no custom event required.

## Requirements

- MediaWiki 1.43 or later;
- Umami 3.2 or later;
- a reachable Umami installation;
- one Umami website ID per tracked wiki.

Umami 3.2 or later is required because the extension uses
`data-auto-pageview="false"` before sending a controlled page view.

## Installation

Clone or copy the extension into the MediaWiki extensions directory:

```bash
cd /path/to/mediawiki/extensions
git clone https://example.org/UmamiAnalytics.git
```

Enable and configure it in `LocalSettings.php`:

```php
wfLoadExtension( 'UmamiAnalytics' );

$wgUmamiAnalyticsScriptUrl =
    'https://stats.example.org/script.js';

$wgUmamiAnalyticsHostUrl =
    'https://stats.example.org';

$wgUmamiAnalyticsWebsiteId =
    '00000000-0000-0000-0000-000000000000';
```

No MediaWiki database update is required.

## Configuration

### `$wgUmamiAnalyticsScriptUrl`

Full URL of the Umami tracker script.

This setting is mandatory.

```php
$wgUmamiAnalyticsScriptUrl =
    'https://stats.example.org/script.js';
```

### `$wgUmamiAnalyticsHostUrl`

Base URL of the Umami collection endpoint.

This setting is optional when the script and the collection endpoint
are served from the same Umami origin.

```php
$wgUmamiAnalyticsHostUrl =
    'https://stats.example.org';
```

### `$wgUmamiAnalyticsWebsiteId`

Umami website UUID.

This setting is mandatory.

```php
$wgUmamiAnalyticsWebsiteId =
    '00000000-0000-0000-0000-000000000000';
```

### `$wgUmamiAnalyticsNamespaces`

List of MediaWiki namespaces included in analytics.

The default value only includes the main namespace:

```php
$wgUmamiAnalyticsNamespaces = [
    NS_MAIN
];
```

Example including project, help and category pages:

```php
$wgUmamiAnalyticsNamespaces = [
    NS_MAIN,
    NS_PROJECT,
    NS_HELP,
    NS_CATEGORY
];
```

### `$wgUmamiAnalyticsExcludeOldRevisions`

Exclude requests containing an `oldid` parameter.

Default:

```php
$wgUmamiAnalyticsExcludeOldRevisions = true;
```

### `$wgUmamiAnalyticsExcludeDiffs`

Exclude requests containing a `diff` parameter.

Default:

```php
$wgUmamiAnalyticsExcludeDiffs = true;
```

### `$wgUmamiAnalyticsRespectDNT`

Do not load the tracker when the browser sends a Do Not Track
preference.

Default:

```php
$wgUmamiAnalyticsRespectDNT = true;
```

## Data model

The extension uses the native Umami page dimensions:

```text
url   = canonical MediaWiki URL
title = MediaWiki display title as plain text
```

Example:

```text
url   = /wiki/Titre_sur_plusieurs_mots
title = Titre sur plusieurs mots
```

The MediaWiki page ID is intentionally not sent because Umami does
not use it as its native page aggregation dimension.

When a page is renamed, the previous URL and the new URL therefore
appear as separate entries in Umami. This is an accepted design
trade-off because renames of the most-viewed pages are uncommon.

## MediaWiki display titles

When a page defines a `DISPLAYTITLE`, the extension sends its rendered
text value to Umami after removing HTML formatting.

For example:

```wikitext
{{DISPLAYTITLE:''Le Petit Prince''}}
```

is sent as:

```text
Le Petit Prince
```

The canonical URL remains based on the actual MediaWiki page title.

## Multi-wiki configuration

A separate Umami website ID should normally be used for each wiki.

```php
wfLoadExtension( 'UmamiAnalytics' );

$wgUmamiAnalyticsScriptUrl =
    'https://stats.example.org/script.js';

$wgUmamiAnalyticsHostUrl =
    'https://stats.example.org';

$umamiWebsiteIds = [
    'vikidia_fr' =>
        '11111111-1111-1111-1111-111111111111',

    'vikidia_en' =>
        '22222222-2222-2222-2222-222222222222',

    'vikidia_es' =>
        '33333333-3333-3333-3333-333333333333'
];

$wgUmamiAnalyticsWebsiteId =
    $umamiWebsiteIds[$wgDBname] ?? null;
```

If no website ID is configured for the current wiki, the extension
remains inactive and does not load the Umami tracker.

## Tracked requests

A normal existing article view is tracked:

```text
/wiki/Titre_sur_plusieurs_mots
```

The following requests are excluded by default:

```text
/wiki/Page?action=edit
/wiki/Page?action=history
/wiki/Page?action=submit
/wiki/Page?oldid=123
/wiki/Page?diff=456
/wiki/Special:RecentChanges
/wiki/Spécial:Modifications_récentes
/wiki/Missing_page
```

Query parameters are not copied into the canonical URL sent to Umami.

## CDN and cache behavior

Tracking continues to work when the MediaWiki page is served from a
CDN cache because the analytics request is sent by the visitor's
browser.

The extension does not insert user-specific information into the
tracking configuration. Cached pages can therefore be shared between
visitors without embedding a MediaWiki user name or user identifier.

The Umami collection response itself must not be cached by the CDN.

## Content Security Policy

If a Content Security Policy is enabled, the Umami origin must be
allowed for both scripts and collection requests.

Conceptual example:

```text
script-src https://stats.example.org
connect-src https://stats.example.org
```

The exact CSP configuration depends on the wiki, CDN and reverse
proxy deployment.

## Privacy

The extension does not send:

- MediaWiki user names;
- MediaWiki user IDs;
- email addresses;
- MediaWiki page IDs;
- revision IDs;
- search terms;
- edit activity;
- watchlist activity;
- custom click events.

The deployment operator remains responsible for:

- configuring Umami appropriately;
- defining retention periods;
- documenting the processing;
- verifying hosting and data transfers;
- informing visitors where required;
- validating the complete installation against applicable law.

## Verification

Open a tracked article and inspect the browser network panel.

The expected sequence is:

1. the ResourceLoader module is loaded;
2. the Umami tracker script is loaded;
3. one page-view request is sent to Umami.

In the browser console:

```javascript
mw.loader.getState( 'ext.umamiAnalytics' );
```

Expected result on a tracked article:

```text
ready
```

Inspect the server-side configuration provided to the module:

```javascript
mw.config.get( 'wgUmamiAnalytics' );
```

Example result:

```javascript
{
    scriptUrl: 'https://stats.example.org/script.js',
    hostUrl: 'https://stats.example.org',
    websiteId: '00000000-0000-0000-0000-000000000000',
    canonicalUrl: '/wiki/Titre_sur_plusieurs_mots',
    pageTitle: 'Titre sur plusieurs mots',
    respectDNT: true
}
```

The Umami dashboard should record:

```text
URL:   /wiki/Titre_sur_plusieurs_mots
Title: Titre sur plusieurs mots
```

Verify that only one page-view request is emitted for each document
load.

## License

GPL-2.0-or-later.