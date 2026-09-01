web: bundle exec rake reservations:backfill_resource_manager_shops data:ensure_unique_indexes && bundle exec puma -t 5:5 -p ${PORT:-3000} -e ${RACK_ENV:-development}
