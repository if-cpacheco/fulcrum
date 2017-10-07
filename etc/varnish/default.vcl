vcl 4.0;

import std;
import directors;

include "include/audience.vcl";
include "internal.vcl";
include "blacklist.vcl";
include "whitelist.vcl";
include "backends-webs.vcl";

# Respond to incoming requests.
sub vcl_recv {
  set req.backend_hint = web.backend();

  include "include/x-forward-for.vcl";

  # If we are hit on http2, it has to be on https.
  # Haproxy cannot do http2 so it has to be in tcp mode and
  # cannot add this header on its own, so let varnish do it.
  if (req.proto ~ "HTTP/2") {
    set req.http.X-Forwarded-Proto = "https";
    set req.http.X-Forwarded-Port = "443";
  }

  # save the left most IP for whitelisting
  set req.http.X-Client-IP = regsub(req.http.X-Forwarded-For, "[, ].*$", "");

  # Only allow BAN requests from IP addresses in the 'purge' ACL.
  if (req.method == "BAN") {
      # Same ACL check as above:
      if (!client.ip ~ internal) {
          return (synth(403, "Not allowed."));
      }
      # We ban based on the url, not tags, as cloudflare business does not handle tags,
      # and drupal likes to do full tags or urls, not both.
      if (req.http.X-Url && req.http.X-Host) {
         # X-Url is not just the part after the domain name, but the whole thing, so we have to chop it up
         set req.http.X-Url = regsub(req.http.X-Url, "^https?://[^/]+/", "/");
         ban("req.http.host == " + req.http.X-Host + " && req.url == " + req.http.X-Url);
      }
      else {
         return (synth(403, "X-Url header or X-Host header missing."));
      }
      # Throw a synthetic page so the request won't go to the backend.
      return (synth(200, "Purge added for " + req.http.X-Host + " - " + req.http.X-Url));
  }

  # Use anonymous, cached pages if all backends are down.
  if (!std.healthy(req.backend_hint)) {
    unset req.http.Cookie;
  }

  # Allow the backend to serve up stale content if it is responding slowly.
  #
  # This is now handled in vcl_hit.
  #
  # set req.grace = 6h;

  # Pipe these paths directly to web server for streaming.
  if (req.url ~ "^/admin/content/backup_migrate/export") {
    return (pipe);
  }

  # site wide ban, may need in future to do the right most, instead of left, most public ip
  if ( std.ip(req.http.X-Client-IP, client.ip) ~ blacklist ) {
    return (synth(403, "Access Denied."));
  }

  # Determines if the "public" part (not /user) can be hit.
  # audience.vcl should either be empty (dev/test) or 0.0.0.0/0 for a public (hinge/prd) setup
  # if IP in whitelist, you get access to both the frontend and /user
  # behind ELB -> HAproxy, it seems $_SERVER['HTTP_X_CLIENT_IP'];, not to be confused with HTTP_X_CLIENTIP
  if ( client.ip !~ audience && std.ip(req.http.X-Client-IP, client.ip) !~ whitelist ) {
    return (synth(403, "Access Denied."));
  }

  # Squash malicious bot requests
  # Do not allow outside access to certain php or txt files
  # Block user login and node add external
  # must be in whitelist.vcl to access /user
  if (req.url ~ "^/((wordpress|wp|old)/wp-admin/?|wp-login.php)$" ||
      ( !std.ip(req.http.X-Client-IP, client.ip) ~ whitelist &&
        ( req.url ~ "^/((apc|authorize|cron|install|phptest|status|update)\.php|[A-Z]{6,11}[a-z\.]*\.txt)$" ||
          req.url ~ "(?i)^/((index.php)?\?q=)?(admin.*|user.*|node/add|simplesaml*)" )
  )) {
    return (synth(403, "Access Denied. " + std.ip(req.http.X-Client-IP, client.ip) ));
  }

  # Do not cache these paths.
  if (req.url ~ "^/(status|update)\.php$" ||
      req.url ~ "^/(admin/build/features|info/|flag/)" ||
      req.url ~ "^.*/(ajax|ahah)/") {
       return (pass);
  }

  # Handle compression correctly. Different browsers send different
  # "Accept-Encoding" headers, even though they mostly all support the same
  # compression mechanisms. By consolidating these compression headers into
  # a consistent format, we can reduce the size of the cache and get more hits.=
  # @see: http:// varnish.projects.linpro.no/wiki/FAQ/Compression
  if (req.http.Accept-Encoding) {
    if (req.http.Accept-Encoding ~ "gzip") {
      # If the browser supports it, we'll use gzip.
      set req.http.Accept-Encoding = "gzip";
    } else if (req.http.Accept-Encoding ~ "deflate") {
      # Next, try deflate if it is supported.
      set req.http.Accept-Encoding = "deflate";
    } else {
      # Unknown algorithm. Remove it and send unencoded.
      unset req.http.Accept-Encoding;
    }
  }

  # Always cache the following file types for all users. This list of extensions
  # appears twice, once here and again in vcl_backend_response so make sure you edit both
  # and keep them equal.
  if (req.url ~ "(?i)\.(svg|woff|png|gif|jpe?g|ico|swf|css|js|html?|ttf)(\?[a-z0-9_=\?&\.-]+)?$") {
    unset req.http.Cookie;
  }

  # Remove all cookies that Drupal doesn't need to know about. ANY remaining
  # cookie will cause the request to pass-through to web server. For the most part
  # we always set the NO_CACHE cookie after any POST request, disabling the
  # Varnish cache temporarily. The session cookie allows all authenticated users
  # to pass through as long as they're logged in.
  if (req.http.Cookie) {

    # simple saml remove cookies else attempting to login goes into a loop
    # https://www.drupal.org/node/2651192
    if (req.http.Cookie ~ "NO_CACHE") {
      return (pass);
    }

    # 1. Append a semi-colon to the front of the cookie string.
    # 2. Remove all spaces that appear after semi-colons.
    # 3. Match the cookies we want to keep, adding the space we removed
    #    previously back. (\1) is first matching group in the regsuball.
    # 4. Remove all other cookies, identifying them by the fact that they have
    #    no space after the preceding semi-colon.
    # 5. Remove all spaces and semi-colons from the beginning and end of the
    #    cookie string.
    set req.http.Cookie = ";" + req.http.Cookie;
    set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
    set req.http.Cookie = regsuball(req.http.Cookie, ";(SESS[a-z0-9]+|SSESS[a-z0-9]+|NO_CACHE)=", "; \1=");
    set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
    set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");

    if (req.http.Cookie == "") {
      # If there are no remaining cookies, remove the cookie header. If there
      # aren't any cookie headers, Varnish's default behavior will be to cache
      # the page.
      unset req.http.Cookie;
    } else {
      # If there is any cookies left (a session or NO_CACHE cookie), do not
      # cache the page. Pass it on to web server directly.
      return (pass);
    }
  }
}

# Set a header to track a cache HIT/MISS.
sub vcl_deliver {

  # it seems varnish doesn't really run these durning the include for whatever reason
  # include "include/cache-tag-remove.vcl";

  # Remove ban-lurker friendly custom headers when delivering to client.
  unset resp.http.X-Url;
  unset resp.http.X-Host;

  # Comment these for easier Drupal cache tag debugging in development.
  unset resp.http.Cache-Tags;
  unset resp.http.X-Drupal-Cache-Contexts;

  # Just things to hide from the public
  unset resp.http.X-Generator;

  set resp.http.Via = "1.1 varnish";

  if (obj.hits > 0) {
    set resp.http.X-Varnish-Cache = "HIT";
  } else {
    set resp.http.X-Varnish-Cache = "MISS";
  }
}

# Routine used to determine the cache key if storing/retrieving a cached page.
sub vcl_hash {
  # hash data based on the domain (host) as to not have conflicts on foo.com/contact & bar.com/contact
  # also seperate based on http vs httpS else http will not redirect if its already in the cache
  # https://bensmann.no/seperate-varnish-caching-http-https/
  if (req.http.host && req.http.X-Forwarded-Proto ~ "https") {
      hash_data(req.http.X-Forwarded-Proto);
  }

  # now use the host (domain) part
  if (req.http.host) {
    hash_data(req.http.host);
  } else {
    hash_data(server.ip);
  }

  # strip off some of the timestamp used by javascript & Drupal itok that gets in the way of caching
  if (req.url ~ "(?i)^.*\.(?:png|gif|jpe?g)\?") {
    hash_data(regsub(req.url, "(?i)^(.*\.(?:png|gif|jpe?g))\?(?:itok=[^?&]+)?(?:[\?&](?:timestamp=)?1[4-6]\d{11})", "\1"));
  } else {
    hash_data(req.url);
  }

  return (lookup);
}

# Code determining what to do when serving items from the web servers.
# beresp == Back-end response from the web server.
sub vcl_backend_response {
  # Set ban-lurker friendly custom headers.
  set beresp.http.X-Url = bereq.url;
  set beresp.http.X-Host = bereq.http.host;

  include "include/beresp-ttl.vcl";

  # large file kludge: dont cache files > 1mb
  # https://gist.github.com/mcphersoncreative/7469629
  if (beresp.http.Content-Length ~ "[0-9]{7,}" ) {
    set beresp.uncacheable = true;
    return (deliver);
  }

  # Don't allow static files to set cookies.
  # This list of extensions appears twice, once here and again in vcl_recv so
  # make sure you edit both and keep them equal.
  if (bereq.url ~ "(?i)\.(svg|woff|png|gif|jpe?g|ico|swf|css|js|html?|ttf)(\?[a-z0-9_=\?&\.-]+)?$") {
    # beresp == Back-end response from the web server.
    unset beresp.http.set-cookie;
  }

  # force cache for 5 minutes
  if (bereq.url ~ "^/(rss\.xml|robots\.txt|sites/all/themes/.*/twitterResults.php)$") {
    unset beresp.http.Cache-Control;
    set beresp.http.Cache-Control = "public, max-age=300";
  }

  # Allow items to be stale if needed.
  set beresp.grace = 6h;
}

# In the event of an error, show friendlier messages.
sub vcl_backend_error {
  # HTML for all
  set beresp.http.Content-Type = "text/html; charset=utf-8";

  # more specific error for those who need to report it
  if (beresp.status == 403) {
    synthetic(std.fileread("/etc/varnish/error-denied.html"));
  } else if (beresp.status == 404) {
    synthetic(std.fileread("/etc/varnish/error-notfound.html"));
  } else if (beresp.status >= 500 && beresp.status <= 599) {
    synthetic(std.fileread("/etc/varnish/error-server.html"));
  } else {
    synthetic(std.fileread("/etc/varnish/error-default.html"));
  }

  return (deliver);
}
