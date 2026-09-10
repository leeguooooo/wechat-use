import { PuppetService } from 'wechaty-puppet-service'

/** Standard Puppet API, with the upstream 1.19.9 location decoder corrected. */
export class WechatUsePuppet extends PuppetService {
  // Upstream retries every MessageSendFile error using its deprecated stream
  // RPC, including lost delivery confirmations. Never replay a native send.
  async messageSendFile(conversationId, fileBox) {
    const client = this.grpcManager.client
    const Request = client.constructor.service.messageSendFile.requestType
    const request = new Request()
    request.setConversationId(conversationId)
    // 1.19.9 passes small Buffer boxes through even though FileBox.toJSON
    // cannot serialize them. Upload non-serializable sources as streams.
    const transferable = fileBox.type === 1 || fileBox.type === 7
      ? fileBox
      : this.FileBoxUuid.fromStream(await fileBox.toStream(), fileBox.name)
    request.setFileBox(await this.serializeFileBox(transferable))
    const response = await new Promise((resolve, reject) => {
      client.messageSendFile(request, { deadline: Date.now() + 150_000 }, (error, value) => {
        if (error) reject(error)
        else resolve(value)
      })
    })
    return response.getId() || undefined
  }

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
