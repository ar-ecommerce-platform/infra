-- Runs once on first container init. One database per service; each service's
-- own user owns its database (a service never touches another's schema).
CREATE DATABASE authdb;
CREATE DATABASE userdb;
CREATE DATABASE productdb;
CREATE DATABASE inventorydb;
CREATE DATABASE paymentdb;
CREATE DATABASE orderdb;
