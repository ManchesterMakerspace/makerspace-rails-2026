# See Service::JobDrain: let jobs queued by a scheduled `rails runner`/rake process finish before it exits.
# Skipped in the test environment, where specs control the queue themselves.
at_exit { Service::JobDrain.wait! } unless Rails.env.test?
