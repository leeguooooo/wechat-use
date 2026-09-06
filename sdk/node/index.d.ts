import { PuppetService } from 'wechaty-puppet-service'
export declare class WechatUsePuppet extends PuppetService {
  messageLocation(messageId: string): Promise<{
    accuracy: number
    address: string
    latitude: number
    longitude: number
    name: string
  }>
}
