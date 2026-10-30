# Good and bad tests

Examples are language-neutral; translate them to the project's test framework and helpers.

## Good: observable behaviour through the interface

```
test "a member can check out a valid cart"
  cart = new_cart() |> add(product)
  assert checkout(cart, payment_method).status == "confirmed"
```

Behaviour a caller cares about; public interface only; survives refactors; says WHAT, not HOW; one logical assertion.

## Bad: coupled to implementation

```
test "checkout calls the payment service"
  mock(payment_service)
  checkout(cart, payment)
  assert called(payment_service.process, cart.total)
```

Red flags: mocks an internal collaborator, tests a private function, asserts call counts or order, breaks on a refactor without a behaviour change, name describes HOW.

## Bad: bypasses the interface to verify

```
test "create_user saves to the database"
  create_user(name: "Alice")
  assert db.query("SELECT * FROM users WHERE name = 'Alice'") != empty
```

Good: verify through the interface.

```
test "create_user makes the user retrievable"
  user = create_user(name: "Alice")
  assert get_user(user.id).name == "Alice"
```

## Bad: tautological

```
test "calculate_total sums line items"
  items = [{price: 10}, {price: 5}]
  assert calculate_total(items) == sum(items.price)     # recomputes the code's formula
```

Good: an independent literal.

```
  assert calculate_total([{price: 10}, {price: 5}]) == 15
```
