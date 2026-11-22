# frozen_string_literal: true

# Creates Postal's first admin. The noixdev.infra.postal role runs it on an
# install through rails runner in the runner service (postal make-user needs a
# terminal). The values come as JSON on stdin (the password among them, never
# in an argument) and none of them is printed. Prints one line:
#   created              the admin was created
#   exists               Postal has a user already; nothing was changed
#   invalid: <messages>  Postal refused the values (its validation messages,
#                        which quote no value)
require "json"

admin = JSON.parse($stdin.read)
if User.count.positive?
  puts "exists"
else
  user = User.new(
    email_address: admin.fetch("email"),
    first_name: admin.fetch("first_name"),
    last_name: admin.fetch("last_name"),
    password: admin.fetch("password"),
    admin: true,
    email_verified_at: Time.now
  )
  if user.save
    puts "created"
  else
    puts "invalid: #{user.errors.full_messages.join('; ')}"
  end
end
