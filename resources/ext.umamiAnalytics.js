( function () {
    'use strict';

    const config = mw.config.get( 'wgUmamiAnalytics' );

    if ( !config ) {
        return;
    }

    if (
        typeof config.scriptUrl !== 'string' ||
        config.scriptUrl === ''
    ) {
        return;
    }

    if (
        typeof config.websiteId !== 'string' ||
        config.websiteId === ''
    ) {
        return;
    }

    if (
        typeof config.canonicalUrl !== 'string' ||
        config.canonicalUrl === ''
    ) {
        return;
    }

    if (
        typeof config.pageTitle !== 'string' ||
        config.pageTitle === ''
    ) {
        return;
    }

    /*
     * Respect Do Not Track only when enabled by the system
     * administrator.
     */
    if (
        config.respectDNT === true &&
        (
            navigator.doNotTrack === '1' ||
            navigator.doNotTrack === 'yes' ||
            window.doNotTrack === '1'
        )
    ) {
        return;
    }

    /*
     * Prevent accidental duplicate execution on the same document.
     *
     * This flag is not persistent and does not identify the visitor.
     */
    if ( window.umamiMediaWikiTrackerLoaded === true ) {
        return;
    }

    window.umamiMediaWikiTrackerLoaded = true;

    const tracker = document.createElement( 'script' );

    tracker.src = config.scriptUrl;
    tracker.async = true;

    tracker.setAttribute(
        'data-website-id',
        config.websiteId
    );

    /*
     * Disable the automatic page view.
     *
     * The extension sends one controlled page view after the tracker
     * has loaded, using the canonical URL and display title resolved
     * by MediaWiki on the server side.
     */
    tracker.setAttribute(
        'data-auto-pageview',
        'false'
    );

    /*
     * Configure the event collection endpoint when it differs from
     * the origin serving the tracker script.
     */
    if (
        typeof config.hostUrl === 'string' &&
        config.hostUrl !== ''
    ) {
        tracker.setAttribute(
            'data-host-url',
            config.hostUrl
        );
    }

    tracker.addEventListener( 'load', function () {
        if (
            !window.umami ||
            typeof window.umami.track !== 'function'
        ) {
            mw.log.warn(
                '[UmamiAnalytics] The tracker loaded, but ' +
                'window.umami.track is unavailable.'
            );

            return;
        }

        /*
         * Preserve Umami's automatically collected properties while
         * replacing the URL and title with values resolved by the
         * MediaWiki extension.
         *
         * Exactly one page view is sent.
         */
        window.umami.track( function ( properties ) {
            return Object.assign(
                {},
                properties,
                {
                    url: config.canonicalUrl,
                    title: config.pageTitle
                }
            );
        } );
    } );

    tracker.addEventListener( 'error', function () {
        mw.log.warn(
            '[UmamiAnalytics] Unable to load the Umami tracker.'
        );
    } );

    document.head.appendChild( tracker );
}() );