require 'uri'

module Parsers
  class KufarParser
    CARD_XPATH = '//*[@data-testid="listing"]//section/a[starts-with(@data-testid, "kufar-realty-card-")]'.freeze

    def self.parse(url, for_sell: false)
      new.parse(url, for_sell)
    end

    def parse(url, for_sell)
      @for_sell = for_sell

      doc = fetch_page(url)
      ad_elements = doc.xpath(CARD_XPATH)

      Rails.logger.info("Kufar: найдено карточек: #{ad_elements.size}")

      if ad_elements.empty?
        raise "Kufar: карточки не найдены — проверь полученный HTML"
      end

      ad_elements.each do |ad_link|
        # ad_link уже является ссылкой <a>.
        href = ad_link['href']
        next if href.blank?

        # Абсолютная ссылка без query-параметров и fragment.
        ad_uri = URI.join(url, href)
        ad_uri.query = nil
        ad_uri.fragment = nil

        href_cleaned = ad_uri.to_s

        # Например:
        # /vi/minsk/snyat/kvartiru/1089624045 → 1089624045
        external_id = ad_uri.path[%r{/(\d+)/?\z}, 1]
        next unless external_id

        # Цена: "2 046 р./мес." → 2046.
        price_node = ad_link.at_xpath(
          './/*[@data-testid="card-price"]'
        )

        price_text = normalized_text(price_node)
        price_digits = price_text&.gsub(/[^\d]/, '')
        price = price_digits.present? ? price_digits.to_i : nil

        # Не сохраняем карточку с отсутствующей или некорректной ценой.
        # Иначе можно ошибочно отправить уведомление об изменении цены.
        unless price&.positive?
          Rails.logger.warn(
            "Kufar: пропускаем объявление #{external_id}: " \
              "не удалось получить цену, текст=#{price_text.inspect}"
          )
          next
        end

        # В HTML сайта атрибут называется именно card-adress,
        # с одной буквой d — это не опечатка в парсере.
        address_node = ad_link.at_xpath(
          './/*[@data-testid="card-adress"]'
        )
        address = normalized_text(address_node)

        # Описание находится в <p> внутри контентного блока.
        # Используем смысловую часть класса без привязки к хешу.
        content_node = ad_link.at_xpath(
          './div[contains(@class, "__content")]'
        )

        description_node = content_node&.at_xpath('./p')
        description = normalized_text(description_node)

        # Берём только фотографии из слайдера:
        # иконка калькулятора и прочие изображения сюда не попадут.
        photo_nodes = ad_link.xpath(
          './/div[contains(concat(" ", normalize-space(@class), " "), " swiper-slide ")]//img'
        )

        photos = photo_nodes.filter_map do |img|
          src = img['data-src'].presence || img['src'].presence
          next if src.blank? || src.start_with?('data:')

          URI.join(href_cleaned, src).to_s
        end.uniq

        title = "Объявление #{external_id}"

        ad_attrs = {
          external_id: external_id,
          site: @for_sell.present? ? 'kufar_for_sell' : 'kufar',
          url: href_cleaned,
          title: title,
          price: price,
          address: address,
          description: description,

          # В присланной карточке дата пустая.
          # Здесь, как и раньше, сохраняется время обработки,
          # а не реальная дата публикации на сайте.
          published_at: Time.current,

          photos: photos
        }

        save_ad(ad_attrs)
      end
    end

    private

    # Убираем лишние пробелы, включая неразрывные.
    def normalized_text(node)
      node&.text
        &.gsub(/[[:space:]\u00A0\u202F]+/, ' ')
        &.strip
        &.presence
    end

    def fetch_page(url)
      response = Faraday.get(url)

      Rails.logger.info(
        "Kufar: HTTP=#{response.status}, " \
          "bytes=#{response.body.to_s.bytesize}"
      )

      unless response.status == 200
        raise "Kufar: неожиданный HTTP-статус #{response.status}"
      end

      Nokogiri::HTML(response.body)
    end

    def save_ad(attributes)
      ad = Ad.find_or_initialize_by(
        site: @for_sell.present? ? 'kufar_for_sell' : 'kufar',
        external_id: attributes[:external_id]
      )

      if ad.new_record?
        Rails.logger.info "Найдено новое объявление: #{attributes}"

        ad.assign_attributes(attributes)

        if ad.valid?
          ad.save!
          notify_telegram(ad)
        else
          Rails.logger.warn(
            "Kufar: объявление #{attributes[:external_id]} невалидно: " \
              "#{ad.errors.full_messages.join(', ')}"
          )
        end
      else
        Rails.logger.info "Найдено старое объявление: #{attributes}"

        # Если у старой записи цена отсутствует,
        # тоже обновляем её, не вызывая price_range с nil.
        if ad.price.nil? || !price_range(ad).include?(attributes[:price])
          old_price = ad.price

          ad.assign_attributes(attributes)

          if ad.valid?
            ad.save!
            notify_telegram(ad, old_price: old_price)
          else
            Rails.logger.warn(
              "Kufar: объявление #{attributes[:external_id]} невалидно: " \
                "#{ad.errors.full_messages.join(', ')}"
            )
          end
        end
      end
    end

    def price_range(ad)
      (ad.price * 0.93..ad.price * 1.07)
    end

    def notify_telegram(ad, old_price: false)
      Telegram::TelegramNotifier.notify_new_ad(
        ad,
        old_price: old_price,
        use_for_sell_chat: @for_sell
      )
    end
  end
end
