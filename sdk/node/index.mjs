import { PuppetService } from 'wechaty-puppet-service'

/** Standard Puppet API, with the upstream 1.19.9 location decoder corrected. */
export class WechatUsePuppet extends PuppetService {
  async messageLocation(messageId) {
    const client = this.grpcManager.client
    const Request = client.constructor.service.messageLocation.requestType
    const request = new Request()
    request.setId(messageId)
    const response = await new Promise((resolve, reject) => {
      client.messageLocation(request, { deadline: Date.now() + 30_000 }, (error, value) => {
        if (error) reject(error)
        else resolve(value)
      })
    })
    const location = response.getLocation()
    if (!location) throw new Error('Message has no location payload')
    return {
      accuracy: location.getAccuracy(),
      address: location.getAddress(),
      latitude: location.getLatitude(),
      longitude: location.getLongitude(),
      name: location.getName(),
    }
  }
}
