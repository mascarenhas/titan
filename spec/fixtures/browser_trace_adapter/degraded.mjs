// Supervisor-policy fixture; it does not claim to be a compiler-produced image.
export default async function() {
    return {titanBrowserTrace: {state: 'degraded', reason: 'intentional missing map',
        mapBytes: 0, loadMilliseconds: 0, indexBytes: 0}};
}
