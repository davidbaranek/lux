# Offering networks to Lux

Lux signs in to WhatsApp, Messenger, Instagram and the other networks through the
[mautrix](https://docs.mau.fi/bridges/) bridges on the account's own server. It finds them and
signs in with their **provisioning API** (bridgev2's `/_matrix/provision/v3`): a website to sign
in on (Lux reads the cookies the bridge needs itself), a QR code to scan, a form. Nobody copies
cookies or talks to a bot.

A server offers its bridges in three steps. Until they are done, Lux says the server offers no
networks, or which part does not answer, and links here.

## 1. Let the bridges take Matrix sign-ins

In each bridge's `config.yaml`:

```yaml
provisioning:
    # any secret of 16 characters or more: an empty one turns the API off.
    shared_secret: generate
    allow_matrix_auth: true
```

Lux never sends the account's access token to a bridge: it sends an OpenID token
(`Authorization: Bearer openid:<token>`, with `?user_id=@you:server`), which the bridge checks
with the account's server over federation (`/_matrix/federation/v1/openid/userinfo`). That
endpoint must answer on the server's federation address (`/.well-known/matrix/server`, or port
8448), which it does on a server that federates.

The user also needs the bridge's `login` permission (`bridge.permissions`, `user` or above).

## 2. Put each provisioning API on the web

Proxy only `/_matrix/provision/` of each bridge, under an `https` address of your choosing. Never
the bridge's other paths: `/_matrix/app/` is the server's own.

Caddy, for a bridge listening on `127.0.0.1:29319`:

```caddy
matrix.example.org {
    handle_path /_lux/bridges/messenger/* {
        @provision path /_matrix/provision/*
        reverse_proxy @provision 127.0.0.1:29319
        respond 404
    }
}
```

On Kubernetes with Traefik, a `Service` and `EndpointSlice` for the bridge, a `Middleware` that
strips `/_lux/bridges/<network>`, and an `Ingress` path
`/_lux/bridges/<network>/_matrix/provision/` to the service.

Check it: `curl https://matrix.example.org/_lux/bridges/messenger/_matrix/provision/v3/whoami`
answers `401` with `M_MISSING_TOKEN`.

## 3. List the bridges in the client well-known

In `https://<server name>/.well-known/matrix/client`, beside `m.homeserver`:

```json
{
  "m.homeserver": { "base_url": "https://matrix.example.org" },
  "com.bardav.lux.bridges": [
    { "network": "messenger", "provisioning": "https://matrix.example.org/_lux/bridges/messenger" },
    { "network": "instagram", "provisioning": "https://matrix.example.org/_lux/bridges/instagram" },
    { "network": "whatsapp", "provisioning": "https://matrix.example.org/_lux/bridges/whatsapp" }
  ]
}
```

`network` is the network's id: `whatsapp`, `signal`, `messenger`, `instagram`, `telegram`,
`discord`, `linkedin`, `slack`, `gmessages`, `imessage`, or any other bridge's protocol id.
`provisioning` is the address of step 2, without `/_matrix/provision/v3`.

With Element Server Suite, the Helm values:

```yaml
wellKnownDelegation:
  additional:
    client: '{"com.bardav.lux.bridges":[{"network":"messenger","provisioning":"https://matrix.example.org/_lux/bridges/messenger"}]}'
```

## What Lux tells the user

| What it finds | What it says |
| --- | --- |
| No `com.bardav.lux.bridges` | The server offers no networks to sign in to from Lux, with a link here. |
| The address does not answer | The bridge does not answer: its server is down or the address is wrong. |
| `401` | The bridge does not accept Lux's sign-in: step 1 is missing. |
| `403` without a reason | The bridge does not let this account sign in: its permissions. |
| `404` | No bridge answers at the address: step 2 is wrong. |

## The history a bridge brings

Bridges do not say when they bring a network's history (backfill). Lux sees it in the sync:
messages the server took long after they were sent (their `unsigned.age` is short, their
`origin_server_ts` long ago). An old message the server took long ago is no history, however
late the sync brings it (an opened chat's latest messages, a sync that starts over). While history
comes, the chat list shows the network loading it; a minute after the last, it is done.
