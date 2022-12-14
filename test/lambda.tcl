proc handler {event context} {
	puts "event: [json pretty $event]"
	if {[json exists $event test]} {
		switch -exact -- [json get $event test] {
			simple-2.1 {
				lambda hook -oneshot post_handle {apply {{} {
					puts "In post_handle"
					lambda shutdown
				}}}
				lambda hook -oneshot shutdown {apply {{} {
					puts "In shutdown"
				}}}
			}
		}
	}
	json template {
		{
			"hello": "world"
		}
	}
}
