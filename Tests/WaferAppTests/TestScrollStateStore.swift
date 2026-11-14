import WaferCore

func makeTestScrollStateStore() -> ScrollStateStore {
    ScrollStateStore(defaults: makeTestUserDefaults())
}
