import { PuppetService } from 'wechaty-puppet-service'
export declare class WechatUsePuppet extends PuppetService {
  messageSendFile(conversationId: string, fileBox: Parameters<PuppetService['messageSendFile']>[1]): Promise<string | void>
  messageLocation(messageId: string): Promise<{
    accuracy: number
    address: string
    latitude: number
    longitude: number
    name: string
  }>
}
