# Ethical Use Guidelines

This toolkit is powerful, and when misused, its activity may be technically indistinguishable from a Denial-of-Service (DoS) attack. Read the following principles carefully before using it.

## Golden Rule

Only test targets that fall into one of the following categories:

1. Systems that you own.
2. Systems for which you have received **written and signed** authorization from the owner. Verbal permission is not sufficient.

## Third-Party Services

Even if the application belongs to you, do not directly load test the third-party services it relies on, such as shared cloud databases or authentication providers.

These services operate on shared infrastructure. Generating heavy load against them may affect other customers and violate the provider’s terms of service.

## Best Practices

* Always begin with a low load and increase it gradually.
* Run tests during low-traffic hours when testing a production environment.
* Inform all relevant teams in advance.
* Use a staging or test environment instead of production whenever possible.
* Keep test data separate from real user data.
* Store authorization documents securely and maintain them regularly.

## Disclaimer

This toolkit is intended for educational and authorized testing purposes only. The user is solely responsible for any consequences resulting from its use.
