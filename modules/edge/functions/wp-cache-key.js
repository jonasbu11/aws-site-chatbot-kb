// CloudFront Function (cloudfront-js-2.0), viewer-request, default behavior.
//
// Page HTML is cached with NO cookies in the cache key, so visitors carrying
// only analytics or consent cookies (_ga, _fbp, cookieyes-consent, ...) share
// cached pages. Visitors carrying a WordPress session cookie must never share
// a cache entry, so for them this function sets x-wp-nocache to a random value.
// That header is in the cache key, which makes every such request a unique
// miss that goes to the origin with the visitor's cookies intact.
//
// Any x-wp-nocache sent by the viewer is discarded, so it can't be used to
// force misses.

var BYPASS_PREFIXES = [
  'wordpress_logged_in_',
  'wordpress_sec_',
  'wp-postpass_',
  'comment_author_',
  'woocommerce_items_in_cart',
  'woocommerce_cart_hash',
  'wp_woocommerce_session_',
  'wordpressuser_',
  'wordpresspass_'
];

function hasSessionCookie(cookies) {
  for (var name in cookies) {
    for (var i = 0; i < BYPASS_PREFIXES.length; i++) {
      if (name.indexOf(BYPASS_PREFIXES[i]) === 0) {
        return true;
      }
    }
  }
  return false;
}

function handler(event) {
  var request = event.request;
  delete request.headers['x-wp-nocache'];

  if (hasSessionCookie(request.cookies || {})) {
    request.headers['x-wp-nocache'] = {
      value: Date.now().toString(36) + Math.random().toString(36).slice(2)
    };
  }
  return request;
}
