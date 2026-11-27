package com.example.platform.app.web;

import com.example.platform.app.security.OidcClientConfig;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Public pages: the landing page and the sign-in chooser. The HTML is static
 * (no request data is echoed back), so there is nothing to escape.
 */
@RestController
public class LoginController {

    static final String OIDC_LOGIN_URL = "/oauth2/authorization/" + OidcClientConfig.REGISTRATION_ID;
    static final String SAML_LOGIN_URL = "/saml2/authenticate/" + OidcClientConfig.REGISTRATION_ID;

    private static final String PAGE = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <title>Sign in</title>
            </head>
            <body>
              <h1>Platform demo application</h1>
              <p>Sign in through Keycloak with either protocol:</p>
              <ul>
                <li><a href="%s">Sign in with OpenID Connect</a></li>
                <li><a href="%s">Sign in with SAML 2.0</a></li>
              </ul>
              <p><a href="/me">Who am I?</a> (requires sign-in)</p>
            </body>
            </html>
            """.formatted(OIDC_LOGIN_URL, SAML_LOGIN_URL);

    @GetMapping(path = {"/", "/login"}, produces = MediaType.TEXT_HTML_VALUE)
    String loginPage() {
        return PAGE;
    }
}
