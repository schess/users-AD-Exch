# Session storage.
# Previously used a server-side :memory_store session (only the session id in the
# cookie; AD admin credentials held in server memory). That did NOT survive
# Passenger's multi-process / smart-spawn model: the GET that issued the CSRF
# token and the POST that verified it could land in different processes, so the
# session was lost and login failed with "The change you wanted was rejected"
# (ActionController::InvalidAuthenticityToken).
#
# Switched to :cookie_store: the whole session (CSRF token + AD admin credentials)
# travels in a cookie that is ENCRYPTED and SIGNED with secret_key_base, so it is
# opaque to the client and works regardless of which Passenger worker handles the
# request.
Rails.application.config.session_store :cookie_store,
                                       key: "_adruby_session",
                                       expire_after: 8.hours
