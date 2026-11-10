import Foundation

/// 把中文检索词转成英文，拼成给 MobileCLIP 的描述（它只认英文）。
/// 这里收的是标签词典覆盖不到、但描述画面常用的词：颜色、时间天气、动作、人物、常见场景和物品。
/// 查不到的中文词不进描述，只用原来的方式（画面标签、图中文字）匹配。
enum PromptLexicon {
    static let english: [String: String] = {
        var m: [String: String] = [:]
        func put(_ en: String, _ words: [String]) { for w in words { m[w] = en } }
        // 颜色
        // 不收「红色的」这类带「的」的写法：「的」要留给分词当分隔符
        put("red", ["红色"]); put("orange", ["橙色", "橘色"]); put("yellow", ["黄色"])
        put("green", ["绿色"]); put("blue", ["蓝色"]); put("purple", ["紫色"]); put("pink", ["粉色", "粉红色", "粉红"])
        put("black", ["黑色"]); put("white", ["白色"]); put("gray", ["灰色"]); put("brown", ["棕色", "咖啡色"])
        put("golden", ["金色"]); put("silver", ["银色"]); put("colorful", ["彩色", "五颜六色"])
        // 时间、天气
        put("at night", ["夜晚", "晚上", "夜里", "夜景", "深夜"]); put("in the daytime", ["白天"])
        put("in the morning", ["早晨", "早上", "清晨"]); put("at dusk", ["黄昏", "傍晚"])
        put("in the rain", ["下雨", "雨天", "雨中", "雨夜"]); put("in the snow", ["下雪", "雪天", "雪中"])
        put("in fog", ["大雾", "雾天"]); put("cloudy", ["阴天"]); put("sunny", ["晴天"])
        put("sunset", ["日落", "夕阳"]); put("sunrise", ["日出"]); put("snowy mountain", ["雪山"])
        put("group photo of people", ["合影", "合照", "集体照"])
        // 动作
        put("riding", ["骑", "骑着"]); put("running", ["跑步", "奔跑"]); put("walking", ["走路", "散步"])
        put("swimming", ["游泳"]); put("dancing", ["跳舞"]); put("playing", ["玩耍", "玩"]); put("eating", ["吃饭", "吃"])
        put("sleeping", ["睡觉", "睡着"]); put("sitting", ["坐着"]); put("standing", ["站着"]); put("flying", ["飞", "飞翔"])
        put("driving", ["开车"]); put("hugging", ["拥抱"]); put("smiling", ["微笑"]); put("jumping", ["跳"])
        // 人物
        put("person", ["人"]); put("people", ["人们", "很多人", "人群"]); put("man", ["男人", "男生"]); put("woman", ["女人", "女生"])
        put("children", ["小孩", "孩子", "儿童", "小朋友"]); put("baby", ["婴儿", "宝宝"]); put("elderly person", ["老人"])
        put("friends", ["朋友"]); put("family", ["家人", "一家人"])
        // 场景
        put("city", ["城市"]); put("street", ["街道", "街上", "马路"]); put("park", ["公园"]); put("garden", ["花园"])
        put("sea", ["大海"]); put("lake", ["湖边", "湖"]); put("river", ["河边", "河"]); put("mountain", ["山上", "大山"])
        put("forest", ["森林", "树林"]); put("bridge", ["桥"]); put("kitchen", ["厨房"]); put("office", ["办公室"])
        put("cherry blossoms", ["樱花"]); put("temple", ["寺", "寺庙", "寺院"])
        put("classroom", ["教室"]); put("restaurant", ["餐厅", "饭店"]); put("supermarket", ["超市"]); put("airport", ["机场"])
        put("station", ["车站"]); put("school", ["学校"]); put("beach", ["海边", "沙滩", "海滩"])
        // 物品、食物
        put("stop sign", ["停车标志", "停车牌", "停止标志"]); put("wine glass", ["酒杯", "红酒杯", "高脚杯"])
        put("baseball bat", ["棒球棒", "球棒"])
        put("bowl", ["碗", "一碗"]); put("cup", ["杯子"]); put("plate", ["盘子"]); put("book", ["书"]); put("phone", ["手机"])
        put("computer", ["电脑"]); put("umbrella", ["雨伞", "伞"]); put("hat", ["帽子"]); put("glasses", ["眼镜"])
        put("sunglasses", ["墨镜"]); put("noodles", ["面条", "面"]); put("ramen", ["拉面"]); put("rice", ["米饭"])
        put("coffee", ["咖啡"]); put("fruit", ["水果"]); put("balloons", ["气球"]); put("fireworks", ["烟花"])
        put("menu", ["菜单"]); put("street sign", ["路牌"]); put("receipt", ["发票", "收据", "小票"])
        // 猫狗品种：Vision 只认到"狗""猫"，MobileCLIP 能分辨不少品种
        put("samoyed", ["萨摩耶"]); put("shiba inu", ["柴犬"]); put("akita dog", ["秋田犬"])
        put("border collie", ["边牧", "边境牧羊犬"]); put("french bulldog", ["法斗", "法国斗牛犬"])
        put("chow chow", ["松狮"]); put("husky", ["哈士奇"]); put("golden retriever", ["金毛"]); put("labrador", ["拉布拉多"])
        put("poodle", ["泰迪", "贵宾犬"]); put("ragdoll cat", ["布偶猫", "布偶"]); put("british shorthair cat", ["英短", "英国短毛猫"])
        put("american shorthair cat", ["美短"]); put("orange tabby cat", ["橘猫"]); put("siamese cat", ["暹罗猫"])
        // 交通
        put("car", ["汽车", "车", "小汽车"]); put("bicycle", ["自行车", "单车"]); put("motorcycle", ["摩托车"])
        put("bus", ["公交车", "巴士"]); put("train", ["火车"]); put("airplane", ["飞机"]); put("boat", ["船"])
        put("hot air balloon", ["热气球"])
        return m
    }()
}
