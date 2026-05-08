#!/usr/bin/env python3
"""Token-authenticated peer endpoint, exposed without web-auth."""
import sys
sys.path.insert(0, "/opt/dyndns/web/cgi-bin")
from api import handle_heartbeat
handle_heartbeat()
