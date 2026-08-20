<?php

declare( strict_types = 1 );

namespace MediaWiki\Extension\UmamiAnalytics;

use MediaWiki\Output\Hook\BeforePageDisplayHook;
use MediaWiki\Output\OutputPage;
use MediaWiki\Page\PageProps;
use MediaWiki\Skin\Skin;
use MediaWiki\Title\Title;

/**
 * Hooks for the UmamiAnalytics extension.
 */
final class Hooks implements BeforePageDisplayHook {

    private PageProps $pageProps;

    public function __construct( PageProps $pageProps ) {
        $this->pageProps = $pageProps;
    }

    /**
     * Loads the Umami tracker on eligible MediaWiki page views.
     *
     * All MediaWiki-specific decisions are made server-side.
     * The ResourceLoader module only loads Umami and sends the
     * canonical URL and display title supplied by this handler.
     *
     * @param OutputPage $out
     * @param Skin $skin
     */
    public function onBeforePageDisplay( $out, $skin ): void {
        $config = $out->getConfig();

        $scriptUrl = $config->get(
            'UmamiAnalyticsScriptUrl'
        );

        $hostUrl = $config->get(
            'UmamiAnalyticsHostUrl'
        );

        $websiteId = $config->get(
            'UmamiAnalyticsWebsiteId'
        );

        /*
         * Leave the extension silently disabled if its mandatory
         * configuration is missing.
         */
        if (
            !is_string( $scriptUrl ) ||
            trim( $scriptUrl ) === ''
        ) {
            return;
        }

        if (
            !is_string( $websiteId ) ||
            trim( $websiteId ) === ''
        ) {
            return;
        }

        $title = $out->getTitle();

        if ( !$title ) {
            return;
        }

        $request = $out->getRequest();

        /*
         * Only count normal page views.
         */
        $action = $request->getVal( 'action', 'view' );

        if ( $action !== 'view' ) {
            return;
        }

        /*
         * Special pages are excluded regardless of their localized
         * namespace name.
         */
        if ( $title->isSpecialPage() ) {
            return;
        }

        /*
         * Do not track missing pages, implicit searches or invalid
         * titles as article views.
         */
        if ( !$title->exists() ) {
            return;
        }

        /*
         * Restrict collection to the namespaces configured by the
         * system administrator.
         */
        $allowedNamespaces = $config->get(
            'UmamiAnalyticsNamespaces'
        );

        if ( !is_array( $allowedNamespaces ) ) {
            return;
        }

        if (
            !in_array(
                $title->getNamespace(),
                $allowedNamespaces,
                true
            )
        ) {
            return;
        }

        /*
         * By default, old revisions are not considered regular
         * article views.
         */
        if (
            $config->get(
                'UmamiAnalyticsExcludeOldRevisions'
            ) &&
            $request->getVal( 'oldid' ) !== null
        ) {
            return;
        }

        /*
         * Revision comparisons are excluded independently from
         * old revision views.
         */
        if (
            $config->get(
                'UmamiAnalyticsExcludeDiffs'
            ) &&
            $request->getVal( 'diff' ) !== null
        ) {
            return;
        }

        /*
         * Build a canonical MediaWiki URL without carrying request
         * parameters such as action, diff, oldid or user-provided
         * query strings.
         */
        $canonicalUrl = $title->getLocalURL();

        /*
         * Obtain the MediaWiki display title when available.
         * Fall back to the prefixed canonical title otherwise.
         */
        $pageTitle = $this->getDisplayTitle( $title );

        $clientConfig = [
            'scriptUrl' => trim( $scriptUrl ),
            'websiteId' => trim( $websiteId ),
            'canonicalUrl' => $canonicalUrl,
            'pageTitle' => $pageTitle,
            'respectDNT' => (bool)$config->get(
                'UmamiAnalyticsRespectDNT'
            )
        ];

        /*
         * data-host-url is optional. It is only provided when the
         * collection endpoint has explicitly been configured.
         */
        if (
            is_string( $hostUrl ) &&
            trim( $hostUrl ) !== ''
        ) {
            $clientConfig['hostUrl'] = rtrim(
                trim( $hostUrl ),
                '/'
            );
        }

        /*
         * Expose one extension-specific configuration object.
         */
        $out->addJsConfigVars(
            'wgUmamiAnalytics',
            $clientConfig
        );

        /*
         * Load the ResourceLoader module owned by the extension.
         */
        $out->addModules(
            'ext.umamiAnalytics'
        );
    }

    /**
     * Returns the MediaWiki display title as plain text.
     *
     * The displaytitle page property may contain permitted HTML
     * formatting. Umami must receive a readable text label rather
     * than HTML markup.
     *
     * @param Title $title
     * @return string
     */
    private function getDisplayTitle( Title $title ): string {
        $displayTitle = '';

        /*
         * DISPLAYTITLE is stored in the page_props table as the
         * "displaytitle" page property.
         */
        $properties = $this->pageProps->getProperties(
            $title,
            'displaytitle'
        );

        $articleId = $title->getArticleID();

        if (
            $articleId > 0 &&
            isset( $properties[$articleId] ) &&
            is_string( $properties[$articleId] )
        ) {
            $displayTitle = trim(
                $properties[$articleId]
            );
        }

        /*
         * Use the normal prefixed MediaWiki title if the page does
         * not define a DISPLAYTITLE.
         */
        if ( $displayTitle === '' ) {
            return $title->getPrefixedText();
        }

        /*
         * Convert permitted DISPLAYTITLE markup into plain text.
         */
        $plainTitle = html_entity_decode(
            strip_tags( $displayTitle ),
            ENT_QUOTES | ENT_HTML5,
            'UTF-8'
        );

        /*
         * Removing HTML formatting can leave duplicated whitespace.
         */
        $normalizedTitle = preg_replace(
            '/\s+/u',
            ' ',
            $plainTitle
        );

        if (
            !is_string( $normalizedTitle ) ||
            trim( $normalizedTitle ) === ''
        ) {
            return $title->getPrefixedText();
        }

        return trim( $normalizedTitle );
    }
}
