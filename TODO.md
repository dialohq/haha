## h2inspect
- [ ] some TUI for displaying tests in parallel
- [ ] server tests
    - [ ] make some file for generic test that are valid for both peers
- [ ] remaining tests
    - SETTINGS impact
    - flow control on streams and on the connection
    - errored stream races
    - last stream id in GOAWAY
    - normal HTTP headers validation
    - server push
    - CONTINUATION frames
    - informational interim responses
- [ ] multicore

- [ ] more functionalities in script cases
    - assume specific amount of data to arrive on last stream
    - assume sepecifc settings in the preface
